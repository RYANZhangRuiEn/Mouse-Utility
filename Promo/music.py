import numpy as np,wave
from pathlib import Path
sr=48000;duration=44;n=int(sr*duration)
audio=np.zeros((n,2),dtype=np.float64)
rng=np.random.default_rng(42)
def hz(m):return 440*2**((m-69)/12)
def place(start,signal,pan=0):
 i=max(0,int(start*sr));end=min(n,i+len(signal));v=signal[:end-i]
 if len(v): audio[i:end,0]+=v*np.sqrt((1-pan)/2);audio[i:end,1]+=v*np.sqrt((1+pan)/2)
def bell(start,note,amp=.045,length=2.3,pan=0):
 t=np.arange(int(length*sr))/sr
 env=(1-np.exp(-t*100))*np.exp(-t*2.4)
 sig=(np.sin(2*np.pi*hz(note)*t)+.22*np.sin(2*np.pi*hz(note)*2.005*t)*np.exp(-t*3)+.06*np.sin(2*np.pi*hz(note)*3*t))*env*amp
 place(start,sig,pan)
# Original, quiet, airy chord bed; no samples or third-party music.
chords=[[53,60,64,69],[57,60,64,67],[48,55,59,62],[55,59,62,64]]
for bar in range(8):
 start=bar*5.5;length=min(7.0,duration-start);t=np.arange(int(length*sr))/sr
 env=np.minimum(1,t/1.2)*np.minimum(1,(length-t)/1.8)
 for j,m in enumerate(chords[bar%4]):
  sig=(np.sin(2*np.pi*hz(m)*t)+.22*np.sin(2*np.pi*hz(m)*2*t))*.018*env
  sig*=.88+.12*np.sin(2*np.pi*.12*t+j)
  place(start,sig,(-.5+j/3))
 for j,note in enumerate([chords[bar%4][1]+12,chords[bar%4][2]+12,chords[bar%4][3]+12,chords[bar%4][2]+12]):
  bell(start+.55+j*1.1,note,.031,3,(-.3 if j%2==0 else .3))
def click(start,amp=.022,pitch=1700):
 t=np.arange(int(.045*sr))/sr;sig=(np.sin(2*np.pi*pitch*t)+.18*rng.normal(size=len(t)))*np.exp(-t*145)*amp;place(start,sig)
for i in range(20):click(11.1+i*.235,.018,1500+70*(i%10))
for i,t0 in enumerate([18.5,20.2,22.3,26.0,26.3,26.7,27.1]):bell(t0,[84,86,88,79,83,86,88][i],.024,.6,0)
for t0 in [4.5,10,17.5,25,31.5,39]:
 t=np.arange(int(.65*sr))/sr
 sig=sum(np.sin(2*np.pi*f*t+2*np.pi*70*t*t) for f in [510,740,1120,1600])/4
 sig*=np.sin(np.pi*np.arange(len(t))/len(t))**3*.012
 place(t0-.25,sig)
# Gentle final resolution.
for j,m in enumerate([72,76,79,83]):bell(39.3+.12*j,m,.043,4.5,(-.3+j*.2))
fade=np.minimum(1,np.arange(n)/sr/1.5)*np.minimum(1,(duration-np.arange(n)/sr)/1.8)
audio*=fade[:,None]
peak=np.max(np.abs(audio));audio*=.30/max(peak,1e-9)
with wave.open(str(Path(__file__).parent/'score.wav'),'wb') as f:
 f.setnchannels(2);f.setsampwidth(2);f.setframerate(sr);f.writeframes((np.clip(audio,-1,1)*32767).astype('<i2').tobytes())
print('Original score:',duration,'s; peak',np.max(np.abs(audio)),'RMS',np.sqrt(np.mean(audio**2)))
