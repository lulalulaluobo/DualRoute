"""Root-only control entry point for the menu bar app."""
import base64
import fcntl
import json
import os
import subprocess
import sys
from pathlib import Path
sys.path.insert(0, '/Library/Application Support/CodexTailscaleGateway')
import split_engine as split

def main():
    if os.geteuid()!=0: raise RuntimeError('需要管理员权限')
    op=sys.argv[1] if len(sys.argv)>1 else 'refresh'
    if op not in ('split','full','refresh','set-config'): raise ValueError('未知操作')
    with (split.BASE/'watch.lock').open('a') as lock:
        fcntl.flock(lock,fcntl.LOCK_EX)
        c=split.config()
        if op in ('split','full'): c['mode']=op
        if op=='set-config':
            update=json.loads(base64.b64decode(sys.argv[2],validate=True))
            if not isinstance(update,dict) or set(update)-{'gateway','extra_direct'}: raise ValueError('未知设置')
            c.update(update)
        c=split.validate_config(c)
        # Validate the stored route list before committing a mode change.
        split.desired(c)
        if op!='refresh': split.atomic(split.BASE/'split-config.json',json.dumps(c))
    proc=subprocess.run([sys.executable,'-I',str(split.BASE/'watch.py'),'--wait'],cwd='/private/tmp',timeout=240)
    if proc.returncode: raise RuntimeError((split.BASE/'status.txt').read_text())
    print((split.BASE/'status.txt').read_text())

if __name__=='__main__':
    try: main()
    except Exception as exc:
        print(str(exc),file=sys.stderr);sys.exit(1)
