export const datasetKinds = new Set(['recommendations', 'top3-validation', 'target10']);
const reply = (data, status=200) => Response.json(data, {status,headers:{'Cache-Control':'no-store'}});
const bytes = value => new TextEncoder().encode(value);
const digest = async value => Array.from(new Uint8Array(await crypto.subtle.digest('SHA-256',bytes(value))), x=>x.toString(16).padStart(2,'0')).join('');

export async function ingest(request, env) {
  if(request.method!=='POST') return reply({error:'method-not-allowed'},405);
  if(!env.DB || !env.UPLOAD_TOKEN) return reply({error:'ingest-not-configured'},503);
  const expected=await digest(`Bearer ${env.UPLOAD_TOKEN}`);
  const actual=await digest(request.headers.get('Authorization')||'');
  let different=0;for(let i=0;i<expected.length;i++) different |= expected.charCodeAt(i)^actual.charCodeAt(i);
  if(different) return reply({error:'unauthorized'},401);
  const reader=request.body?.getReader();if(!reader)return reply({error:'empty-body'},400);
  const chunks=[];let size=0;
  for(;;){const {done,value}=await reader.read();if(done)break;size+=value.length;if(size>1500000){await reader.cancel();return reply({error:'payload-too-large'},413);}chunks.push(value);}
  const buffer=new Uint8Array(size);let offset=0;for(const chunk of chunks){buffer.set(chunk,offset);offset+=chunk.length;}
  let input;try{input=JSON.parse(new TextDecoder().decode(buffer));}catch{return reply({error:'invalid-json'},400);}
  const {kind,sourceAt,data}=input||{};
  if(!datasetKinds.has(kind)||!data||typeof data!=='object'||Array.isArray(data))return reply({error:'invalid-dataset'},400);
  if(kind==='recommendations'&&(!Array.isArray(data.items)||!Array.isArray(data.mediumTerm?.items)))return reply({error:'invalid-recommendations'},400);
  if(typeof sourceAt!=='string'||!/(Z|[+-]\d\d:\d\d)$/.test(sourceAt)||!Number.isFinite(Date.parse(sourceAt))||Date.parse(sourceAt)>Date.now()+300000)return reply({error:'invalid-source-time'},400);
  const source=new Date(sourceAt).toISOString(),received=new Date().toISOString();
  const payload=JSON.stringify(data),hash=await digest(payload);
  await env.DB.batch([
    env.DB.prepare('INSERT OR IGNORE INTO dataset_snapshots(kind,digest,source_day,source_at,received_at,payload) VALUES(?,?,?,?,?,?)').bind(kind,hash,new Date(Date.parse(source)+9*3600000).toISOString().slice(0,10),source,received,payload),
    env.DB.prepare(`INSERT INTO published_datasets(kind,source_at,received_at,digest,payload) VALUES(?,?,?,?,?)
      ON CONFLICT(kind) DO UPDATE SET source_at=excluded.source_at,received_at=excluded.received_at,digest=excluded.digest,payload=excluded.payload
      WHERE excluded.source_at > published_datasets.source_at`).bind(kind,source,received,hash,payload)
  ]);
  return reply({ok:true,kind,digest:hash,sourceAt:source});
}

export async function readDataset(kind, env) {
  const row=await env.DB.prepare('SELECT source_at,received_at,payload FROM published_datasets WHERE kind=?').bind(kind).first();
  if(!row)return reply({status:'not-connected',items:[],message:'D1 연결 완료 · Windows 자료 업로드 대기'},503);
  const data=JSON.parse(row.payload);
  data.storage={backend:'D1',sourceAt:row.source_at,receivedAt:row.received_at,stale:Date.now()-Date.parse(row.source_at)>96*3600000};
  return reply(data);
}
