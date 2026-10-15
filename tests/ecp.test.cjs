const test = require('node:test');
const assert = require('node:assert/strict');
const {authResponse, translate, connect} = require('../bin/roku-ecp.cjs');

test('authentication matches a published protocol capture', () => {
  assert.equal(authResponse('3KwH7h3HTmxFziLtrzVg5w=='), '6yYiyDKcbca3qwig1hylU0dHqUQ=');
});
test('key, Unicode typing, query, and launch paths map to ECP-2 commands', () => {
  assert.deepEqual(translate('/keypress/PowerOn'), ['key-press', {'param-key':'PowerOn'}]);
  assert.deepEqual(translate('/keypress/Lit_%E2%82%AC'), ['key-press', {'param-key':'Lit_€'}]);
  assert.deepEqual(translate('/launch/12'), ['launch', {'param-channel-id':'12'}]);
  assert.deepEqual(translate('/query/apps'), ['query-apps', {}]);
  assert.deepEqual(translate('/query/audio-device'), ['query-audio-device', {}]);
  assert.deepEqual(translate('/launch/837?contentId=8_UnANdDqJc&mediaType=movie&t=10'), ['launch', {
    'param-channel-id':'837',
    'param-params':JSON.stringify({contentId:'8_UnANdDqJc',mediaType:'movie',t:'10'})
  }]);
  assert.throws(() => translate('/query/unknown'));
});
test('invalid targets are rejected', async () => {
  await assert.rejects(connect('not-a-device'), /IPv4/);
});

test('authenticated requests correlate replies and surface denied controls', async () => {
  const original = global.WebSocket;
  const sent = [];
  class FakeSocket extends EventTarget {
    static OPEN = 1;
    readyState = 1;
    constructor() { super(); queueMicrotask(()=>this.message({notify:'authenticate', 'param-challenge':'challenge'})); }
    message(value) { const event = new Event('message'); event.data = JSON.stringify(value); this.dispatchEvent(event); }
    send(data) {
      const message = JSON.parse(data); sent.push(message);
      queueMicrotask(()=>this.message({response:message.request, 'response-id':message['request-id'], status:message.request==='key-press'?'403':'200', 'status-msg':'Forbidden'}));
    }
    close() { this.readyState = 3; this.dispatchEvent(new Event('close')); }
  }
  global.WebSocket = FakeSocket;
  let client;
  try {
    client = await connect('127.0.0.1', 100);
    assert.equal(sent[0].request, 'authenticate');
    assert.equal(sent[0]['param-has-microphone'], 'false');
    assert.equal((await client.request('query-device-info')).status, '200');
    await assert.rejects(client.request('key-press', {'param-key':'Home'}), error=>error.status===403);
    assert.equal(sent.filter(m=>m.request==='key-press').length, 1);
  } finally { if (client) client.close(); global.WebSocket = original; }
});
