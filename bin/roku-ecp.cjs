#!/usr/bin/env node
// Independent ECP-2 client based on published protocol observations:
// https://mr.scot/blog/how-i-built-roam/ (Scott Driggers)
const {createHash} = require('node:crypto');
const {isIP} = require('node:net');

function authResponse(challenge) {
  const seed = '95E610D0-7C29-44EF-FB0F-97F1FCE4C297';
  const key = seed.replace(/[0-9A-F]/g, c => ((24 - parseInt(c, 16)) & 15).toString(16).toUpperCase());
  return createHash('sha1').update(challenge + key).digest('base64');
}

function connect(ip, timeout = 5000) {
  if (isIP(ip) !== 4) return Promise.reject(new Error('A valid IPv4 address is required'));
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(`ws://${ip}:8060/ecp-session`, 'ecp-2');
    let sequence = 0;
    let authenticated = false;
    const pending = new Map();
    const fail = error => {
      clearTimeout(authTimer);
      for (const entry of pending.values()) { clearTimeout(entry.timer); entry.reject(error); }
      pending.clear();
      if (!authenticated) reject(error);
    };
    const authTimer = setTimeout(() => { fail(new Error('ECP-2 authentication timed out')); ws.close(); }, timeout);
    const request = (command, params = {}) => new Promise((ok, bad) => {
      const id = String(++sequence);
      const timer = setTimeout(() => { pending.delete(id); bad(new Error(`${command} timed out`)); }, timeout);
      pending.set(id, {resolve:ok, reject:bad, timer});
      try { ws.send(JSON.stringify({request:command, 'request-id':id, ...params})); }
      catch (error) { clearTimeout(timer); pending.delete(id); bad(error); }
    });
    ws.addEventListener('error', () => fail(new Error('ECP-2 connection failed')));
    ws.addEventListener('close', () => fail(new Error('ECP-2 connection closed')));
    ws.addEventListener('message', event => {
      let message;
      try { message = JSON.parse(event.data); } catch { fail(new Error('Invalid ECP-2 message')); ws.close(); return; }
      if (message.notify === 'authenticate' && !authenticated) {
        if (typeof message['param-challenge'] !== 'string') { fail(new Error('Missing authentication challenge')); ws.close(); return; }
        request('authenticate', {
          'param-response':authResponse(message['param-challenge']),
          'param-client-friendly-name':'Omarchy Roku Remote',
          'param-has-microphone':'false',
          'param-microphone-sample-rates':'16000'
        }).then(() => {
          authenticated = true;
          clearTimeout(authTimer);
          resolve({request, close:()=>ws.close(), isOpen:()=>ws.readyState === WebSocket.OPEN});
        }).catch(error => { fail(error); ws.close(); });
        return;
      }
      const entry = pending.get(String(message['response-id']));
      if (!entry) return;
      pending.delete(String(message['response-id']));
      clearTimeout(entry.timer);
      const status = Number(message.status);
      if (status >= 200 && status < 300) entry.resolve(message);
      else {
        const error = new Error(`${message.response || 'ECP-2'}: ${message['status-msg'] || status}`);
        error.status = status;
        entry.reject(error);
      }
    });
  });
}

function translate(path) {
  let match = /^\/keypress\/(.+)$/.exec(path);
  if (match) return ['key-press', {'param-key':decodeURIComponent(match[1])}];
  match = /^\/launch\/([^/?]+)$/.exec(path);
  if (match) return ['launch', {'param-channel-id':match[1]}];
  match = /^\/query\/(device-info|apps|active-app|media-player)$/.exec(path);
  if (match) return ['query-' + match[1], {}];
  throw new Error('Unsupported ECP-2 path');
}

async function main() {
  const [ip, path] = process.argv.slice(2);
  let client;
  try {
    const [command, params] = translate(path || '');
    client = await connect(ip);
    const response = await client.request(command, params);
    process.stdout.write(JSON.stringify(response) + '\n');
  } catch (error) {
    process.stderr.write(error.message + '\n');
    process.exitCode = 1;
  } finally { if (client) client.close(); }
}

async function bridge() {
  const readline = require('node:readline');
  const sessions = new Map();
  const websocketDevices = new Set();
  const queues = new Map();
  const input = readline.createInterface({input:process.stdin});
  async function perform(message) {
    const {ip, path} = message;
    if (isIP(ip) !== 4) throw new Error('Invalid device IP');
    if (path === '/keypress/PowerOn') {
      const {promisify} = require('node:util');
      const {execFile} = require('node:child_process');
      const {join} = require('node:path');
      const result = await promisify(execFile)(join(__dirname, 'roku'), ['-d', ip, 'poweron'], {timeout:50000});
      return {status:200, transport:'power-on', message:result.stdout.trim()};
    }
    const [command, params] = translate(path);
    if (!websocketDevices.has(ip)) {
      const response = await fetch(`http://${ip}:8060${path}`, {method:command.startsWith('query-') ? 'GET' : 'POST', body:command.startsWith('query-') ? undefined : '', signal:AbortSignal.timeout(3000)});
      await response.arrayBuffer();
      if (response.status !== 403) return {status:response.status, transport:'http'};
      websocketDevices.add(ip);
    }
    let client = sessions.get(ip);
    try {
      if (!client || !client.isOpen()) { client = await connect(ip); sessions.set(ip, client); }
      const response = await client.request(command, params);
      return {status:Number(response.status), transport:'ecp-2'};
    } catch (error) { sessions.delete(ip); if (client) client.close(); throw error; }
  }
  input.on('line', line => {
    let message;
    try { message = JSON.parse(line); } catch { return; }
    const before = queues.get(message.ip) || Promise.resolve();
    const next = before.then(async () => {
      let result;
      try { result = await perform(message); }
      catch (error) { result = {status:error.status || 0, error:error.message}; }
      process.stdout.write(JSON.stringify({id:message.id, ...result}) + '\n');
    });
    queues.set(message.ip, next);
    next.finally(() => { if (queues.get(message.ip) === next) queues.delete(message.ip); });
  });
  input.on('close', async () => {
    await Promise.all(queues.values());
    for (const client of sessions.values()) client.close();
  });
}
if (require.main === module) {
  if (process.argv[2] === '--bridge') bridge();
  else main();
}
module.exports = {authResponse, translate, connect};
