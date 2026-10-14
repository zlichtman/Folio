#!/usr/bin/env node
// End-to-end browser capture check against the real Folio binary, using an isolated library in /private/tmp.
// The real extension scripts run with mocked browser APIs; Folio, its HTTP service, downloads and SQLite are real.
// Usage: node scripts/test-capture.mjs [path/to/Folio] [report.json]   (quit Folio first: the check needs port 53187)
import assert from 'node:assert/strict';
import { spawn, execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { mkdtemp, readFile, rm, stat, writeFile } from 'node:fs/promises';
import http from 'node:http';
import net from 'node:net';
import path from 'node:path';
import vm from 'node:vm';
import zlib from 'node:zlib';
import { setTimeout as sleep } from 'node:timers/promises';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));
const shared = path.join(here,'..','Extensions','shared');
// Defaults to the app build-app.sh stages outside the checkout.
const stage = path.join(process.env.FOLIO_BUILD_CACHE || '/private/tmp/folio-build','stage');
const binary = process.argv[2] || process.env.FOLIO_BINARY || path.join(stage,'Folio.app','Contents','MacOS','Folio');
const output = process.argv[3];
const SERVICE = 'http://127.0.0.1:53187';
const checks = [];
const processes = new Set();

function png(width, height, rgb) {
  const chunk = (type, data) => {
    const out = Buffer.alloc(12 + data.length), name = Buffer.from(type,'ascii');
    out.writeUInt32BE(data.length,0); name.copy(out,4); data.copy(out,8);
    out.writeUInt32BE(zlib.crc32(Buffer.concat([name,data])),8 + data.length);
    return out;
  };
  const header = Buffer.alloc(13); header.writeUInt32BE(width,0); header.writeUInt32BE(height,4); header[8] = 8; header[9] = 2;
  const rows = Buffer.alloc((width * 3 + 1) * height);
  for (let y = 0; y < height; y++) for (let x = 0; x < width; x++) rows.set(rgb,y * (width * 3 + 1) + 1 + x * 3);
  return Buffer.concat([Buffer.from([0x89,0x50,0x4e,0x47,0x0d,0x0a,0x1a,0x0a]),chunk('IHDR',header),chunk('IDAT',zlib.deflateSync(rows)),chunk('IEND',Buffer.alloc(0))]);
}

const library = await mkdtemp('/private/tmp/folio-capture-test-');
const database = path.join(library,'index.sqlite');
const image = png(6,4,[40,90,200]), photo = png(5,5,[200,60,40]), snapshotPNG = png(8,6,[20,20,20]);
await writeFile(path.join(library,'snapshot.png'),snapshotPNG);
execFileSync('/usr/bin/sips',['-s','format','jpeg',path.join(library,'snapshot.png'),'--out',path.join(library,'snapshot.jpg')],{stdio:'ignore'});
const jpeg = await readFile(path.join(library,'snapshot.jpg'));
const mp4 = Buffer.concat([Buffer.from([0,0,0,0x18]),Buffer.from('ftypisom','ascii'),Buffer.alloc(64)]);

const fixture = http.createServer((req,res) => {
  const send = (type, body) => { res.writeHead(200,{'Content-Type':type,'Content-Length':body.length}); res.end(body); };
  switch (req.url) {
    case '/image.png': return send('text/plain',image); // The server type is wrong on purpose.
    case '/photo': return send('image/png',photo);
    case '/clip.mp4': return send('application/octet-stream',mp4);
    case '/fake.jpg': return send('image/jpeg',Buffer.from('<!doctype html><title>Not an image</title>'));
    case '/app.png': return send('image/png',Buffer.concat([Buffer.from([0xcf,0xfa,0xed,0xfe,7,0,0,1]),Buffer.alloc(4096)]));
    case '/disk.png': return send('image/png',Buffer.concat([image,Buffer.alloc(2048,1),Buffer.from('koly','ascii'),Buffer.alloc(508)]));
    case '/archive.png': return send('image/png',Buffer.concat([image,Buffer.from([0x50,0x4b,0x05,0x06]),Buffer.alloc(18)]));
    case '/redirect': res.writeHead(302,{Location:'/photo'}); return res.end();
    case '/huge.png':
      res.writeHead(200,{'Content-Type':'image/png','Content-Length':100 * 1024 * 1024 + 1}); res.write(Buffer.concat([image,Buffer.alloc(8192)]));
      return void setTimeout(() => res.destroy(),15000);
    case '/endless.png': {
      res.writeHead(200,{'Content-Type':'image/png'}); res.write(image);
      const block = Buffer.alloc(1024 * 1024); let sent = 0;
      const pump = () => { while (!res.destroyed && sent < 160 && res.write(block)) sent++; if (!res.destroyed && sent < 160) res.once('drain',pump); else res.end(); };
      res.on('close',() => { sent = 160; });
      return pump();
    }
    default: res.writeHead(404); return res.end('missing');
  }
});
await new Promise(resolve => fixture.listen(0,'127.0.0.1',resolve));
const local = `http://127.0.0.1:${fixture.address().port}`;

function launch(lib, extra = []) {
  const child = spawn(binary,['--library',lib,'--headless-capture',...extra],{stdio:['ignore','pipe','pipe']});
  child.log = ''; child.stdout.on('data',d => { child.log += d; }); child.stderr.on('data',d => { child.log += d; });
  child.exited = new Promise(resolve => child.on('exit',resolve));
  processes.add(child);
  return child;
}
async function quit(child) { child.kill('SIGTERM'); await child.exited; processes.delete(child); }
async function ready(key) {
  for (let i = 0; i < 150; i++) {
    try { if ((await fetch(SERVICE + '/health',{headers:{Authorization:'Bearer ' + key}})).ok) return; } catch (_) {}
    await sleep(100);
  }
  throw new Error('Folio did not start the capture service');
}
const portBusy = () => new Promise(resolve => {
  const socket = net.connect(53187,'127.0.0.1'); socket.on('connect',() => { socket.destroy(); resolve(true); }); socket.on('error',() => resolve(false));
});
function raw(bytes) {
  return new Promise(resolve => {
    const socket = net.connect(53187,'127.0.0.1'), chunks = [];
    socket.on('data',c => chunks.push(c)); socket.on('error',() => {});
    socket.on('close',() => resolve(Number(Buffer.concat(chunks).toString('latin1').split(' ')[1]) || 0));
    socket.end(bytes); setTimeout(() => socket.destroy(),5000);
  });
}
const sql = (text) => text.replaceAll("'","''");
const rows = (query) => { const out = execFileSync('/usr/bin/sqlite3',['-json',database,query],{encoding:'utf8'}).trim(); return out ? JSON.parse(out) : []; };
// Schema v3: memberships live in item_collections; an item in no collection is in the Inbox.
const item = (where) => rows(`SELECT id,path,url,title,source,kind,coalesce((SELECT group_concat(c.name,'|') FROM item_collections m
  JOIN collections c ON c.id=m.collection WHERE m.item=items.id),'Inbox') AS collection FROM items WHERE ${where}`)[0];
const quarantined = (file) => { try { return execFileSync('/usr/bin/xattr',['-p','com.apple.quarantine',file],{encoding:'utf8'}).trim().length > 0; } catch (_) { return false; } };
const mediaFile = (url, ext) => path.join(library,'media',createHash('sha256').update(url).digest('hex') + '.' + ext);
async function check(name, body) {
  try { await body(); checks.push({name,passed:true}); }
  catch (error) { checks.push({name,passed:false,error:error.message}); }
}

let key;
const api = (route, { body, headers = {} } = {}) => fetch(SERVICE + route,{
  method: body ? 'POST' : 'GET', headers: {Authorization:'Bearer ' + key,...(body ? {'Content-Type':'application/json'} : {}),...headers},
  ...(body ? {body:JSON.stringify(body)} : {})
});

try {
  assert.equal(await portBusy(),false,'Quit Folio first: port 53187 is in use.');

  // Phase 1: the service exactly as shipped.
  let folio = launch(library);
  for (let i = 0; i < 100 && !key; i++) { try { key = (await readFile(path.join(library,'capture-key'),'utf8')).trim(); } catch (_) { await sleep(50); } }
  await ready(key);
  await check('Key file is owner-only',async () => {
    assert.match(key,/^[a-f0-9]{64}$/); assert.equal((await stat(path.join(library,'capture-key'))).mode & 0o777,0o600);
  });
  await check('Unpaired and wrong keys rejected',async () => {
    assert.equal((await fetch(SERVICE + '/health')).status,401);
    assert.equal((await fetch(SERVICE + '/health',{headers:{Authorization:'Bearer ' + 'f'.repeat(64)}})).status,401);
  });
  await check('Web page origins rejected, extension origins allowed',async () => {
    for (const origin of ['https://example.com','null']) assert.equal((await api('/health',{headers:{Origin:origin}})).status,403,origin);
    for (const origin of ['moz-extension://abc','chrome-extension://abc']) assert.equal((await api('/health',{headers:{Origin:origin}})).status,200,origin);
  });
  await check('DNS rebinding host names rejected',async () => {
    assert.equal(await raw(`GET /health HTTP/1.1\r\nHost: evil.test:53187\r\nAuthorization: Bearer ${key}\r\n\r\n`),421);
    assert.equal(await raw(`GET /health HTTP/1.1\r\nHost: localhost:53187\r\nAuthorization: Bearer ${key}\r\n\r\n`),200);
  });
  await check('Malformed requests rejected and the service keeps running',async () => {
    assert.equal(await raw('GARBAGE\r\n\r\n'),400);
    assert.equal(await raw(Buffer.from([0x47,0x45,0x54,0x20,0xff,0xfe,0x00,0x0d,0x0a,0x0d,0x0a])),400);
    assert.equal(await raw('POST /save HTTP/1.1\r\nHost: 127.0.0.1:53187\r\nTransfer-Encoding: chunked\r\n\r\n'),501);
    assert.equal(await raw('GET /health HTTP/1.1\r\nX: ' + 'a'.repeat(20000) + '\r\n\r\n'),431);
    assert.equal(await raw(`POST /save HTTP/1.1\r\nHost: 127.0.0.1:53187\r\nContent-Length: ${13 * 1024 * 1024}\r\n\r\n`),413);
    assert.equal(await raw('GET /health HTTP/1.1\r\nHost: 127.0.0.1:53187\r\nHost: evil.test\r\n\r\n'),400);
    assert.equal((await api('/save')).status,405); assert.equal((await api('/nothing')).status,404);
    assert.equal((await api('/save',{body:{url:'https://example.com',kind:'program'}})).status,400);
    assert.equal((await api('/health')).status,200);
  });
  await check('Only web addresses accepted',async () => {
    for (const url of ['file:///etc/hosts','javascript:alert(1)','https://user:pw@example.com/a.png']) {
      assert.equal((await api('/save',{body:{url,kind:'image'}})).status,400,url);
    }
  });
  await check('Downloads from this Mac refused',async () => {
    for (const url of [local + '/image.png',local.replace('127.0.0.1','localhost') + '/image.png']) {
      const response = await api('/save',{body:{url,kind:'image'}});
      assert.equal(response.status,422); assert.match((await response.json()).error,/public web/);
    }
  });
  await check('Saved links keep the target and the page',async () => {
    const response = await api('/save',{body:{url:'https://example.com/article',source:'https://news.example/today',title:'An article',kind:'link',collection:'Reading'}});
    assert.equal(response.status,200);
    const saved = item("url='https://example.com/article'");
    assert.deepEqual([saved.path,saved.source,saved.collection,saved.kind,saved.title],
                     ['https://example.com/article','https://news.example/today','Reading','link','An article']);
    assert.equal((await response.json()).collection,'Reading');
  });
  await check('A typed collection is created',async () => {
    assert.ok((await (await api('/collections')).json()).collections.includes('Reading'));
  });
  await check('Page snapshots saved by content and quarantined',async () => {
    const url = 'https://example.com/page';
    const result = await (await api('/save',{body:{url,title:'Example page',kind:'page',snapshot:jpeg.toString('base64'),collection:'Pages'}})).json();
    assert.equal(result.kind,'link'); assert.equal(result.collection,'Pages');
    const file = mediaFile(url,'jpg');
    assert.deepEqual(await readFile(file),jpeg); assert.ok(quarantined(file));
    const saved = item(`id='${sql(result.id)}'`);
    assert.deepEqual([saved.kind,saved.url,saved.path,saved.source,saved.collection],['link',url,file,url,'Pages']);
    const plain = await (await api('/save',{body:{url:'https://example.com/plain',kind:'page',snapshot:Buffer.from('#!/bin/sh').toString('base64')}})).json();
    assert.equal(plain.kind,'link'); assert.equal(plain.collection,'Inbox');
    assert.equal(item(`id='${sql(plain.id)}'`).path,'https://example.com/plain');
  });
  await check('A busy port does not quit a second copy',async () => {
    const other = await mkdtemp('/private/tmp/folio-capture-test-');
    const second = launch(other);
    await sleep(3000);
    const alive = second.exitCode === null, log = second.log;
    await quit(second); await rm(other,{recursive:true,force:true});
    assert.ok(alive,'second copy exited'); assert.match(log,/keep trying/);
  });
  await quit(folio);

  // Phase 2: allow the local fixture server so downloads and the extension can be exercised end to end.
  folio = launch(library,['--allow-local-downloads']);
  await ready(key);
  const store = {key}, menus = [], notes = [], listeners = {};
  let badge = '';
  const pick = (k) => Object.fromEntries((Array.isArray(k) ? k : [k]).map(name => [name,store[name]]));
  const event = (name) => ({addListener: fn => { listeners[name] = fn; }});
  const tab = {url:'https://example.com/board',title:'Board',windowId:1,id:7};
  const browser = {
    storage:{local:{get:async k => pick(k),set:async o => { Object.assign(store,o); }},onChanged:event('changed')},
    browserAction:{setBadgeText:async ({text}) => { badge = text; },setBadgeBackgroundColor:async () => {}},
    notifications:{create:async (id,options) => { notes.push(options.message); return id; }},
    tabs:{query:async () => [tab],captureVisibleTab:async () => 'data:image/jpeg;base64,' + jpeg.toString('base64')},
    runtime:{id:'folio-test',getURL:p => 'moz-extension://folio-test/' + p,onInstalled:event('installed'),onStartup:event('startup'),onMessage:event('message')},
    contextMenus:{removeAll:async () => { menus.length = 0; },create:(o,done) => { menus.push(o.id); done?.(); },onClicked:event('menu')},
    commands:{onCommand:event('command')}
  };
  const context = vm.createContext({browser,fetch,AbortController,URL,console,setTimeout,clearTimeout,Promise});
  vm.runInContext(await readFile(path.join(shared,'background.js'),'utf8'),context);
  const run = (expression, values = {}) => { Object.assign(context,values); return vm.runInContext(expression,context); };
  const message = (msg, sender) => new Promise(resolve => listeners.message(msg,sender,resolve));
  const popup = {id:'folio-test',url:'moz-extension://folio-test/popup.html'};
  const count = () => rows('SELECT count(*) AS n FROM items')[0].n;

  await check('Context menus registered',async () => { await sleep(50); assert.deepEqual([...menus].sort(),['image','link','page','video']); });
  let first;
  await check('Images saved by their bytes, not the server type',async () => {
    first = await run('onMenu(info,tab)',{info:{menuItemId:'image',srcUrl:local + '/image.png',pageUrl:'https://example.com/gallery'},tab});
    const saved = item(`id='${sql(first.id)}'`);
    assert.equal(saved.kind,'image'); assert.equal(saved.source,'https://example.com/gallery'); assert.equal(saved.title,'image.png');
    assert.equal(saved.url,local + '/image.png');
    assert.ok(saved.path.endsWith('.png')); assert.deepEqual(await readFile(saved.path),image); assert.ok(quarantined(saved.path));
    assert.equal(badge,'✓');
  });
  await check('The badge clears after 3 seconds',async () => { await sleep(3300); assert.equal(badge,''); });
  await check('Repeat captures are not duplicated',async () => {
    const before = count();
    const again = await run('onMenu(info,tab)',{info:{menuItemId:'image',srcUrl:local + '/image.png',pageUrl:'https://example.com/gallery'},tab});
    assert.equal(again.id,first.id); assert.equal(count(),before);
  });
  for (const [name,route,pattern] of [['Fake images refused','/fake.jpg',/not an image/],['Executables refused','/app.png',/not an image/],
                                      ['Disk images refused','/disk.png',/not an image/],['Archives refused','/archive.png',/not an image/],
                                      ['Oversized media refused','/huge.png',/100 MB/],['Media past 100 MB while streaming refused','/endless.png',/100 MB/],
                                      ['Missing media reported','/missing.png',/refused/]]) {
    await check(name,async () => {
      const before = count(), noted = notes.length;
      await assert.rejects(run('saveMedia("image",url,"https://example.com/","")',{url:local + route}),pattern);
      assert.equal(count(),before); assert.equal(badge,'!');
      assert.equal(notes.length,noted + 1,'failure notification'); assert.match(notes.at(-1),pattern);
    });
  }
  await check('Videos saved as videos',async () => {
    const result = await run('saveMedia("video",url,"https://example.com/v","Clip")',{url:local + '/clip.mp4'});
    const saved = item(`id='${sql(result.id)}'`); assert.equal(saved.kind,'video'); assert.ok(saved.path.endsWith('.mp4')); assert.equal(saved.title,'Clip');
  });
  await check('Redirects followed',async () => {
    const result = await run('saveMedia("image",url,"https://example.com/r","")',{url:local + '/redirect'});
    assert.equal(item(`id='${sql(result.id)}'`).kind,'image');
  });
  await check('The popup creates a typed collection and remembers it',async () => {
    const response = await message({type:'savePage',collection:'Brand new'},popup);
    assert.equal(response.ok,true,response.error); assert.equal(response.collection,'Brand new'); assert.equal(store.collection,'Brand new');
    const list = await message({type:'collections'},popup);
    assert.ok(list.collections.includes('Brand new')); assert.equal(list.last,'Brand new');
    assert.ok(quarantined(mediaFile(tab.url,'jpg')));
  });
  await check('Save link uses the link as the item and the page as its source',async () => {
    const result = await run('onMenu(info,tab)',{info:{menuItemId:'link',linkUrl:'https://example.org/target',linkText:'Target link',pageUrl:tab.url},tab});
    const saved = item(`id='${sql(result.id)}'`);
    assert.deepEqual([saved.url,saved.path,saved.source,saved.title,saved.kind,saved.collection],
                     ['https://example.org/target','https://example.org/target',tab.url,'Target link','link','Brand new']);
  });
  await check('Option-click saves the image under the pointer',async () => {
    const content = {};
    const img = {tagName:'IMG',currentSrc:local + '/photo',src:'',style:{outline:'',outlineOffset:''},getAttribute:n => n === 'alt' ? 'Red swatch' : null,querySelector:() => null};
    const overlay = {tagName:'DIV'};
    let sent;
    const contentBrowser = {storage:browser.storage,runtime:{sendMessage:msg => (sent = message(msg,{id:'folio-test',tab,url:tab.url}))}};
    const page = vm.createContext({browser:contentBrowser,document:{elementsFromPoint:() => [overlay,img]},addEventListener:(type,fn) => { content[type] = fn; },setTimeout,Promise});
    vm.runInContext(await readFile(path.join(shared,'content.js'),'utf8'),page);
    let prevented = false;
    const click = {isTrusted:true,altKey:true,button:0,metaKey:false,ctrlKey:false,shiftKey:false,clientX:4,clientY:4,target:overlay,
                   preventDefault:() => { prevented = true; },stopImmediatePropagation:() => {}};
    content.click({...click,isTrusted:false}); content.click({...click,altKey:false});
    assert.equal(sent,undefined,'only trusted Option-clicks save');
    content.click(click);
    const response = await sent;
    assert.equal(response.ok,true,response.error); assert.ok(prevented);
    const saved = item(`id='${sql(response.id)}'`);
    assert.deepEqual([saved.kind,saved.source,saved.title,saved.collection],['image',tab.url,'Red swatch','Brand new']);
  });
  await check('Pages cannot use privileged extension messages',async () => {
    const response = await message({type:'health'},{id:'folio-test',tab,url:tab.url});
    assert.equal(response.ok,false);
  });
  await check('The extension refuses to send without a key',async () => {
    store.key = ''; await assert.rejects(run('callApp("/health")'),/Connect the extension/); store.key = key;
  });
  await quit(folio);
} finally {
  for (const child of processes) child.kill('SIGKILL');
  fixture.close();
  await rm(library,{recursive:true,force:true});
}

const failed = checks.filter(c => !c.passed);
const report = {passed:checks.length - failed.length,failed:failed.length,checks,
  scope:'Real Folio binary, HTTP service, downloads, SQLite and files in an isolated library; real extension scripts with mocked browser APIs. Browser installation and UI are not exercised.'};
if (output) await writeFile(output,JSON.stringify(report,null,2) + '\n');
console.log(JSON.stringify(report,null,2));
process.exit(failed.length ? 1 : 0);
