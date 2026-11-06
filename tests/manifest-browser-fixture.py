"""Only loopback HTTP fixtures for manifest/cookie regression; no Pilot databases."""
from http.server import ThreadingHTTPServer,BaseHTTPRequestHandler
from pathlib import Path
import http.client,json,threading,time
root=Path(__file__).resolve().parents[1]/'test-results'/'manifest-proxy-browser'
html=(root.parent/'pilot-index-original.html').read_text(encoding='utf-8')
head=html[:html.lower().find('</head>')+7]
page=(head+"""<body><h1>Проверка манифеста Pilot</h1>
<p>HTML head взят из официального образа Pilot Web. Кнопка проверяет запрос с режимом credentials, указанным у ссылки manifest.</p>
<button id="check">Проверить манифест</button><pre id="result">Ожидание проверки</pre>
<script>document.getElementById('check').onclick=async()=>{
 const link=document.querySelector('link[rel=manifest]');const credentials=link.crossOrigin==='use-credentials'?'include':'omit';
 try{const response=await fetch(link.href,{credentials,mode:'cors'});const value=await response.json();document.getElementById('result').textContent=JSON.stringify({status:response.status,credentials,name:value.name},null,2);}
 catch(error){document.getElementById('result').textContent='Ошибка загрузки манифеста: '+error.message;}
};</script></body></html>""").encode()
class Upstream(BaseHTTPRequestHandler):
 def log_message(self,*args):pass
 def do_GET(self):
  path=self.path.split('?')[0]
  if path=='/manifest.json':data=json.dumps(dict(name='Pilot manifest regression',short_name='Pilot',start_url='/',display='standalone')).encode();typ='application/manifest+json'
  elif path.endswith('.js'):data=b'';typ='application/javascript'
  elif path.endswith('.css'):data=b'';typ='text/css'
  elif path=='/' or path.startswith('/documents'):data=page;typ='text/html; charset=utf-8'
  else:data=b'<svg xmlns="http://www.w3.org/2000/svg"/>';typ='image/svg+xml'
  self.send_response(200);self.send_header('Content-Type',typ);self.send_header('Content-Length',str(len(data)));self.end_headers();self.wfile.write(data)
class Edge(BaseHTTPRequestHandler):
 def log_message(self,*args):pass
 def do_GET(self):
  target=17100 if self.server.server_port==17101 else 17110
  headers={k:v for k,v in self.headers.items() if k.lower() not in ['connection','host']};headers['Host']='127.0.0.1:'+str(self.server.server_port)
  conn=http.client.HTTPConnection('127.0.0.1',target,timeout=20);conn.request('GET',self.path,headers=headers);response=conn.getresponse();data=response.read()
  if self.path.split('?')[0]=='/manifest.json':
   with (root/'manifest-requests.jsonl').open('a',encoding='utf-8') as file:file.write(json.dumps(dict(port=self.server.server_port,status=response.status,hasSession='pilot_env_session=' in headers.get('Cookie',''),destination=headers.get('Sec-Fetch-Dest','')))+'\n')
  self.send_response(response.status)
  for k,v in response.getheaders():
   if k.lower() not in ['connection','transfer-encoding','content-length','server','date']:self.send_header(k,v)
  self.send_header('Content-Length',str(len(data)));self.end_headers();self.wfile.write(data);conn.close()
for port,handler in [(17102,Upstream),(17101,Edge),(17111,Edge)]:
 server=ThreadingHTTPServer(('127.0.0.1',port),handler);threading.Thread(target=server.serve_forever,daemon=True).start()
while True:time.sleep(60)
