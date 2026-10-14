#!/usr/bin/env node
// Offline checks for both browser extensions: manifests, referenced files, icon sizes, script syntax and risky APIs.
// Usage: node scripts/check-extensions.mjs [report.json]. Exits 1 when anything fails.
import { readFile, readdir, writeFile, access } from 'node:fs/promises';
import path from 'node:path';
import vm from 'node:vm';
import { fileURLToPath } from 'node:url';
const root = path.join(path.dirname(fileURLToPath(import.meta.url)),'..','Extensions');
const shared = path.join(root,'shared');
const errors = [], checked = [];
const fail = (browser,message) => errors.push(`${browser}: ${message}`);
const exists = file => access(path.join(shared,file)).then(() => true,() => false);
const allowedPermissions = new Set(['activeTab','contextMenus','notifications','storage','http://127.0.0.1/*']);

async function pngSize(file) {
  const data = await readFile(path.join(shared,file));
  if (data.readUInt32BE(0) !== 0x89504e47 || data.toString('ascii',12,16) !== 'IHDR') return null;
  return [data.readUInt32BE(16),data.readUInt32BE(20)];
}
async function icons(browser,map,label) {
  for (const [size,file] of Object.entries(map || {})) {
    if (!(await exists(file))) { fail(browser,`${label} ${file} is missing`); continue; }
    const dims = await pngSize(file);
    if (!dims || dims[0] !== Number(size) || dims[1] !== Number(size)) fail(browser,`${label} ${file} is not a ${size}px PNG`);
  }
}
async function page(browser,file) {
  if (!file || !(await exists(file))) { fail(browser,`page ${file} is missing`); return; }
  const html = await readFile(path.join(shared,file),'utf8');
  for (const [,ref] of html.matchAll(/(?:src|href)="([^"]+)"/g)) {
    if (/^[a-z]+:/i.test(ref)) fail(browser,`${file} loads remote ${ref}`);
    else if (!(await exists(ref))) fail(browser,`${file} references missing ${ref}`);
  }
  if (/<script(?![^>]*\bsrc=)[^>]*>/i.test(html)) fail(browser,`${file} has an inline script`);
}

const scripts = (await readdir(shared)).filter(f => f.endsWith('.js'));
for (const file of scripts) {
  const code = await readFile(path.join(shared,file),'utf8');
  try { new vm.Script(code,{filename:file}); } catch (error) { fail('shared',`${file} has a syntax error: ${error.message}`); }
  for (const [pattern,why] of [[/\beval\s*\(/,'eval'],[/new\s+Function\s*\(/,'new Function'],[/\.innerHTML\s*=/,'innerHTML'],[/document\.write\s*\(/,'document.write'],
                               [/https?:\/\/(?!127\.0\.0\.1:53187)/,'a remote address']]) {
    if (pattern.test(code)) fail('shared',`${file} uses ${why}`);
  }
}

const manifests = {};
for (const browser of ['Firefox','Chrome']) {
  let m;
  try { m = manifests[browser] = JSON.parse(await readFile(path.join(root,browser,'manifest.json'),'utf8')); }
  catch (error) { fail(browser,`manifest.json is invalid: ${error.message}`); continue; }
  if (!m.name || m.name.length > 45) fail(browser,'name is missing or longer than 45 characters');
  if (!/^\d+(\.\d+){0,3}$/.test(m.version || '')) fail(browser,'version must be dotted numbers');
  if (!m.description || m.description.length > 132) fail(browser,'description is missing or longer than 132 characters');
  for (const permission of [...(m.permissions || []),...(m.host_permissions || [])]) {
    if (!allowedPermissions.has(permission)) fail(browser,`unexpected permission ${permission}`);
  }
  for (const script of m.content_scripts || []) {
    for (const match of script.matches || []) if (!/^https?:\/\/\*\/\*$/.test(match)) fail(browser,`content script match ${match} is broader than web pages`);
    for (const file of script.js || []) if (!(await exists(file))) fail(browser,`content script ${file} is missing`);
  }
  await icons(browser,m.icons,'icon');
  await page(browser,m.options_ui?.page);
  for (const [,command] of Object.entries(m.commands || {})) {
    if (!/^(Alt|Ctrl|Command|MacCtrl)(\+(Shift|Alt|Ctrl))?\+[A-Z0-9]$/.test(command.suggested_key?.default || '')) fail(browser,'invalid command shortcut');
  }
  if (browser === 'Firefox') {
    if (m.manifest_version !== 2) fail(browser,'expected manifest_version 2');
    const gecko = m.browser_specific_settings?.gecko;
    if (gecko?.id !== 'capture@lumashelf.local') fail(browser,'the add-on ID must stay capture@lumashelf.local');
    if (!gecko?.strict_min_version || !gecko?.data_collection_permissions) fail(browser,'gecko settings are incomplete');
    if (!m.background?.scripts?.length || m.background.service_worker) fail(browser,'needs background scripts, not a service worker');
    for (const file of m.background?.scripts || []) if (!(await exists(file))) fail(browser,`background ${file} is missing`);
    if (m.action || m.host_permissions) fail(browser,'Manifest V3 keys in a Manifest V2 manifest');
    await icons(browser,m.browser_action?.default_icon,'toolbar icon');
    await page(browser,m.browser_action?.default_popup);
  } else {
    if (m.manifest_version !== 3) fail(browser,'expected manifest_version 3');
    if (!m.background?.service_worker || m.background.scripts) fail(browser,'needs a service worker');
    if (m.background?.service_worker && !(await exists(m.background.service_worker))) fail(browser,'service worker file is missing');
    if (m.browser_action || (m.permissions || []).some(p => p.includes('://'))) fail(browser,'Manifest V2 keys in a Manifest V3 manifest');
    if (!(m.host_permissions || []).includes('http://127.0.0.1/*')) fail(browser,'needs the local Folio host permission');
    await icons(browser,m.action?.default_icon,'toolbar icon');
    await page(browser,m.action?.default_popup);
  }
  checked.push(browser);
}
if (manifests.Firefox && manifests.Chrome && manifests.Firefox.version !== manifests.Chrome.version) fail('both','versions differ');

const report = { passed: errors.length === 0, checked, scripts, errors, scope: 'Offline manifest, file, icon and script checks. Not a browser install test.' };
if (process.argv[2]) await writeFile(process.argv[2],JSON.stringify(report,null,2) + '\n');
console.log(JSON.stringify(report,null,2));
process.exit(errors.length ? 1 : 0);
