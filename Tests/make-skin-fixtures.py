# SPDX-License-Identifier: GPL-3.0-or-later
"""Original minimal Delta skin fixtures, no third-party skin assets."""
import copy,json,struct,sys,warnings,zipfile,zlib
from pathlib import Path
out=Path(sys.argv[1]);out.mkdir(parents=True,exist_ok=True)
def chunk(name,data):return struct.pack('>I',len(data))+name+data+struct.pack('>I',zlib.crc32(name+data))
png=b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',2,2,8,6,0,0,0))+chunk(b'IDAT',zlib.compress(b'\0'+b'\0\0\0\xff'*2+b'\0'+b'\0\0\0\xff'*2))+chunk(b'IEND',b'')
def rect(x,y,w,h):return dict(x=x,y=y,width=w,height=h)
def manifest(system):
 dual=system in ['3ds','ds']; keys=['a','b','start','select','menu']
 if system in ['3ds','ds','gba']:keys+=['l','r']
 if dual:keys+=['x','y']
 if system=='3ds':keys+=['circle']
 layouts={}
 for orientation,w,h in [('portrait',400,800),('landscape',800,400)]:
  items=[dict(inputs={k:k for k in ['up','down','left','right']},frame=rect(10,100,80,80))]
  for n,k in enumerate(keys):
   inputs={x:'leftThumbstick'+x.title() for x in ['up','down','left','right']} if k=='circle' else [k]
   items.append(dict(inputs=inputs,frame=rect(10+n%5*55,280+n//5*50,44,44)))
  screens=[dict(outputFrame=rect(120,40,240,144 if system=='3ds' else 180))]
  if dual:screens.append(dict(outputFrame=rect(120,190,100,75)))
  layouts[orientation]=dict(mappingSize=dict(width=w,height=h),assets=dict(resizable='controller.png'),screens=screens,items=items)
 return dict(name='Original '+system.upper()+' test skin',identifier='test.claw.'+system,gameTypeIdentifier='com.rileytestut.delta.game.'+('ds' if system=='ds' else system),representations=dict(iphone=dict(standard=layouts)))
def write(name,value,extra=None,compression=zipfile.ZIP_DEFLATED):
 with zipfile.ZipFile(out/(name+'.deltaskin'),'w',compression=compression) as z:
  z.writestr('info.json',json.dumps(value));z.writestr('controller.png',png)
  z.writestr('empty-credit.txt',b'')
  for n,data in (extra or {}).items():z.writestr(n,data)
for system in ['3ds','ds','gba','gb','gbc','nes']:write(system,manifest(system))
v=manifest('gb');v['gameTypeIdentifier']='public.aoshuang.game.gb';write('manic',v)
(out/'manic.manicskin').write_bytes((out/'manic.deltaskin').read_bytes())
write('stored',manifest('gb'),compression=zipfile.ZIP_STORED)
write('traversal',manifest('gb'),{'../escape.txt':b'no'})
v=manifest('gb');v['gameTypeIdentifier']='unsupported.psp';write('wrong-system',v)
v=manifest('gb');v['representations']['iphone']['standard']['portrait']['items']=[i for i in v['representations']['iphone']['standard']['portrait']['items'] if i['inputs']!=['menu']];write('missing-menu',v)
v=manifest('gb');v['representations']['iphone']['standard']['portrait']['assets']['resizable']='../controller.png';write('resource-traversal',v)
v=manifest('gb');v['representations']['iphone']['standard']['portrait']['items'][0]['frame']['width']=99999;write('bad-frame',v)
v=manifest('gb');v['representations']['iphone']['standard']['portrait']['items'].append(dict(inputs=['unsupportedExtension'],frame=rect(1,1,20,20)));write('optional-action',v)
with zipfile.ZipFile(out/'bad-image.deltaskin','w',compression=zipfile.ZIP_DEFLATED) as z:
 z.writestr('info.json',json.dumps(manifest('gb')));z.writestr('controller.png',b'not an image')
with warnings.catch_warnings():
 warnings.simplefilter('ignore')
 with zipfile.ZipFile(out/'duplicate.deltaskin','w') as z:
  z.writestr('info.json','{}');z.writestr('info.json','{}')
with zipfile.ZipFile(out/'symlink.deltaskin','w') as z:
 entry=zipfile.ZipInfo('link');entry.create_system=3;entry.external_attr=0o120777<<16;z.writestr(entry,'../outside')
b=bytearray((out/'stored.deltaskin').read_bytes());local=30+struct.unpack_from('<H',b,26)[0]+struct.unpack_from('<H',b,28)[0];b[local]^=1;(out/'corrupt.deltaskin').write_bytes(b)
b=bytearray((out/'gb.deltaskin').read_bytes());central=b.index(b'PK\x01\x02');struct.pack_into('<I',b,central+24,128*1024*1024);(out/'oversized.deltaskin').write_bytes(b)
(out/'not-a-skin.deltaskin').write_bytes(b'not a zip')

v=manifest('ds')
for variant in v['representations']['iphone']['standard'].values():
 item=copy.deepcopy(variant['items'][0]);item['frame']=rect(10,190,70,70)
 item['thumbstick']=dict(name='controller.png',width=70,height=70)
 variant['items'].append(item)
write('digital-thumbstick',v)

# The same input may intentionally appear in more than one visual region.
# Both frames must survive import and artwork drawing.
v=manifest('gb')
for variant in v['representations']['iphone']['standard'].values():
 item=copy.deepcopy(next(i for i in variant['items'] if i['inputs']==['a']))
 item['frame']=rect(300,10,40,40)
 variant['items'].append(item)
write('duplicate-controls',v)

# Both canvas kinds, used to verify edge-to-edge fill and standard fit.
v=manifest('gb');v['name']='Original edge-to-edge test skin'
v['representations']['iphone']['edgeToEdge']=copy.deepcopy(v['representations']['iphone']['standard'])
write('edge-to-edge',v)

# Valid, highly compressible 33.5M-pixel source. Build rows incrementally so the
# fixture generator itself never allocates the 128 MiB decoded bitmap.
compressor=zlib.compressobj()
compressed=[]
for _ in range(4096):compressed.append(compressor.compress(b'\0'*(1+8192*4)))
compressed.append(compressor.flush())
(out/'oversized-source.png').write_bytes(b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',8192,4096,8,6,0,0,0))+chunk(b'IDAT',b''.join(compressed))+chunk(b'IEND',b''))
