"""Publish stored reports to the authenticated Worker; no tunnel required."""
import argparse
import json
from datetime import datetime, timezone, timedelta
from pathlib import Path
from urllib.request import Request, urlopen
from urllib.parse import urlparse

ROOT = Path(__file__).resolve().parent.parent
FILES = {'recommendations':'web-recommendations.json', 'top3-validation':'ai-top3-validation.json', 'target10':'target10/latest.json'}

def publish(config_path):
    config=json.loads(Path(config_path).read_text(encoding='utf-8-sig'))
    origin=config['workerUrl'].rstrip('/')
    parsed=urlparse(origin)
    if parsed.scheme!='https' or parsed.path or parsed.query or parsed.username:
        raise ValueError('Worker URL must be an HTTPS origin')
    outcomes=[]
    for kind, filename in FILES.items():
        path=ROOT/'reports'/filename
        if not path.exists():
            outcomes.append({'kind':kind,'status':'missing-file'})
            continue
        data=json.loads(path.read_text(encoding='utf-8-sig'))
        stamp=data.get('generatedAtISO') or data.get('generatedAt')
        if not stamp:
            outcomes.append({'kind':kind,'status':'missing-source-time'})
            continue
        source=datetime.fromisoformat(stamp.replace('Z','+00:00'))
        if source.tzinfo is None: source=source.replace(tzinfo=timezone(timedelta(hours=9)))
        body=json.dumps({'kind':kind,'sourceAt':source.isoformat(),'data':data},ensure_ascii=False,allow_nan=False,separators=(',',':')).encode()
        request=Request(origin+'/api/ingest',data=body,method='POST',headers={
            'Authorization':'Bearer '+config['uploadToken'],'Content-Type':'application/json',
            'User-Agent':'TopPicks-Publisher/1.0'})
        with urlopen(request,timeout=45) as response:
            result=json.load(response)
        outcomes.append({'kind':kind,'status':'uploaded','sourceAt':result['sourceAt'],'digest':result['digest']})
    return outcomes

if __name__=='__main__':
    parser=argparse.ArgumentParser()
    parser.add_argument('--config',default=str(ROOT/'key/cloudflare-upload.json'))
    args=parser.parse_args()
    print(json.dumps(publish(args.config),ensure_ascii=False))
