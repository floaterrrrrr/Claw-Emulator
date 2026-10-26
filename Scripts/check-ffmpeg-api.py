#!/usr/bin/env python3
"""Verify every modern Cytrus FFmpeg dlsym name against both embedded slices."""
import re
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]

def main():
    source=(ROOT/'ThirdParty/Cytrus/common/dynamic_library/ffmpeg.cpp').read_text()
    required={}
    for library,symbol in re.findall(r'LOAD_SYMBOL\((\w+),\s*(\w+)\)',source):
        if library not in ('avutil','avcodec','avfilter','avformat','swresample'): continue
        if symbol in ('av_opt_child_class_next','swr_alloc_set_opts'): continue
        required.setdefault(library,set()).add(symbol)
    for library,symbols in required.items():
        for variant in ('ios-arm64','ios-arm64-simulator'):
            framework=ROOT/f'ThirdParty/Dependencies/FFmpeg/lib{library}.xcframework/{variant}/lib{library}.framework'
            binary=framework/('lib'+library)
            listing=subprocess.check_output(['xcrun','nm','-gU',str(binary)],text=True)
            exported={line.split()[-1].removeprefix('_') for line in listing.splitlines() if line.split()}
            missing=sorted(symbols-exported)
            if missing: raise RuntimeError(f'{library} {variant} missing Cytrus functions: {missing}')
    print(f'PASS: {sum(map(len,required.values()))} Cytrus FFmpeg functions exported by device and simulator frameworks')

if __name__=='__main__': main()
