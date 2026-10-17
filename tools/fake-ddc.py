#!/usr/bin/env python3
import sys,time,json,pathlib
root=pathlib.Path(sys.argv[1]);args=sys.argv[2:]
time.sleep(.018 if args[2]=='set' else .025)
state=root/'state';value=int(state.read_text())
if args[2]=='set':value=int(args[4]);state.write_text(str(value))
with (root/'commands.jsonl').open('a') as f:f.write(json.dumps({'at':time.time(),'command':args,'value':value})+'\n')
print('Writing '+str(value) if args[2]=='set' else value)
