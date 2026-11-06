"""Loopback-only UI fault fixture. Never calls Docker or touches Pilot data."""
import json,time,uuid,threading,argparse
from pathlib import Path
from http.server import ThreadingHTTPServer,BaseHTTPRequestHandler
from urllib.parse import urlparse,parse_qs
parser=argparse.ArgumentParser();parser.add_argument('--web',required=True);parser.add_argument('--state',required=True);args=parser.parse_args()
web=Path(args.web);state_file=Path(args.state);ops=[];idempotency={};lock=threading.RLock();build='f'*64
components=['pilot-server','pilot-bim-server','pilot-web-server','pilot-web-myadmin']
def stamp(t=None):
 from datetime import datetime,timezone
 return datetime.fromtimestamp(t or time.time(),timezone.utc).isoformat()
def environment(name):return dict(name=name,owner='Проверка интерфейса',description='Тестовый стенд',mode='bim-dev',state='running',components=[dict(name=c,state='running',healthy=True) for c in components],webUrl='http://127.0.0.1:18000',adminUrl='http://127.0.0.1:19000')
envs={n:environment(n) for n in ['fixture-a','fixture-b']}
for i in range(35):ops.append(dict(id=str(uuid.uuid4()),kind='restart',environmentName='fixture-a',component='pilot-web-server',state='succeeded',createdAt=stamp(time.time()-1000-i),startedAt=stamp(time.time()-999-i),finishedAt=stamp(time.time()-998-i)))
def flags():
 try:return json.loads(state_file.read_text(encoding='utf-8-sig'))
 except:return {}
def update():
 for op in ops:
  if '_accepted' not in op:continue
  age=time.time()-op['_accepted'];op['state']='queued' if age<5 else 'running' if age<18 else 'succeeded'
  if age>=5:op['startedAt']=stamp(op['_accepted']+5)
  if age>=18:
   op['finishedAt']=stamp(op['_accepted']+18)
   if op['kind']=='delete':envs.pop(op['environmentName'],None)
 def summary(op):return {k:v for k,v in op.items() if not k.startswith('_')}
class Handler(BaseHTTPRequestHandler):
 def log_message(self,*args):pass
 def send(self,value,status=200,content='application/json'):
  data=json.dumps(value,ensure_ascii=False).encode() if content=='application/json' else value
  self.send_response(status);self.send_header('Content-Type',content+'; charset=utf-8');self.send_header('Content-Length',str(len(data)));self.send_header('Cache-Control','no-store');self.end_headers();self.wfile.write(data)
 def do_GET(self):
  path=urlparse(self.path).path;q=parse_qs(urlparse(self.path).query)
  if path=='/':return self.send((web/'index.html').read_text(encoding='utf-8').replace('__ASSETS__','/ui-assets/'+build).encode(),content='text/html')
  if path.startswith('/ui-assets/'):
   name=Path(path).name
   if name not in ['app.js','styles.css']:return self.send({},404)
   return self.send((web/name).read_bytes(),content='text/css' if name.endswith('css') else 'text/javascript')
  f=flags()
  if f.get('offline') and path!='/api/v1/session':return self.send(dict(code='fixture_offline'),503)
  if path=='/api/v1/session':return self.send(dict(csrfToken='local-fixture',publicHost='127.0.0.1',allowedPorts=[17076]))
  if path=='/api/v1/platform':return self.send(dict(apiContractVersion=2,components={c:dict(buildHash=build) for c in ['web-ui','control-api','environment-engine']},capabilities=[] if f.get('legacy') else ['operations-journal-v1']))
  if path=='/api/v1/capacity':return self.send(dict(canStart=True,availableSlots=2,blockers=[],memory=dict(reservedGiB=16,dockerTotalGiB=40),disk=dict(freeGiB=100),publicPorts=dict(availablePairs=48)))
  with lock:
   update()
   if path=='/api/v1/environments':
    result=[]
    for env in envs.values():
     item=dict(env);history=[x for x in ops if x['environmentName']==item['name']]
     if history:
      op=history[0];item['lastOperation']={k:v for k,v in op.items() if not k.startswith('_')}
      if op['state'] in ['queued','running']:item['activeOperationId']=op['id']
     result.append(item)
    return self.send(result)
   if path=='/api/v1/operations':
    rows=[{k:v for k,v in x.items() if not k.startswith('_')} for x in ops]
    for key in ['environmentName','kind','state']:
     v=q.get(key,[None])[0]
     if v:rows=[x for x in rows if x[key]==v or (key=='state' and v=='active' and x[key] in ['queued','running'])]
    offset=int(q.get('cursor',['0'])[0]);limit=int(q.get('limit',['25'])[0]);return self.send(dict(items=rows[offset:offset+limit],nextCursor=str(offset+limit) if offset+limit<len(rows) else None))
   if path.startswith('/api/v1/operations/'):
    op=next((x for x in ops if x['id']==path.split('/')[-1]),None)
    return self.send({k:v for k,v in op.items() if not k.startswith('_')} if op else {},200 if op else 404)
  return self.send({},404)
 def do_DELETE(self):self.do_POST()
 def do_POST(self):
  path=urlparse(self.path).path
  body=json.loads(self.rfile.read(int(self.headers.get('Content-Length','0'))) or b'{}')
  with lock:
   key=self.headers.get('Idempotency-Key');existing=idempotency.get(key)
   if existing:return self.send(dict(operationId=existing['id'],state=existing['state']),202)
   if path=='/api/v1/environments':name=body['name'];kind='create';envs[name]=environment(name);component=None
   elif path=='/api/v1/releases/refresh':name='$release-validation';kind='refresh-release';component=None
   else:
    parts=path.split('/');name=parts[4];kind='delete' if self.command=='DELETE' else parts[-1];component=parts[-2] if 'components' in parts else None
   time.sleep(4)
   op=dict(id=str(uuid.uuid4()),kind=kind,environmentName=name,component=component,state='queued',createdAt=stamp(),startedAt=None,finishedAt=None,_accepted=time.time())
   ops.insert(0,op);idempotency[key]=op
  return self.send(dict(operationId=op['id'],state=op['state']),202)
ThreadingHTTPServer(('127.0.0.1',17076),Handler).serve_forever()
