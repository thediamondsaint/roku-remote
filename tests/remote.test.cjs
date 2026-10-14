const {readFileSync} = require('node:fs');
const vm = require('node:vm');
const test = require('node:test');
const assert = require('node:assert/strict');
const qml = readFileSync(new URL('../Remote.qml', `file://${__filename}`), 'utf8');
function setup() {
  const root = {opened: true, generation: 1, infoGeneration: 1, ip: 'A', devices: [{ip:'A',name:'Living'}, {ip:'B',name:'Bedroom'}], apps: [], pinned: [], fallbackApps: []};
  const infoProc = {running:false};
  const context = vm.createContext({root, infoProc, scanProc:{running:false}, shortcutProc:{running:false}, Qt:{callLater:fn=>fn()}, keyCatcher:{forceActiveFocus(){}}, XMLHttpRequest: function() {}});
  const functions = [...qml.matchAll(/^  function \w+\([^\n]*\) \{[\s\S]*?^  \}/gm)].map(m=>m[0]).join('\n');
  vm.runInContext(functions, context);
  for (const name of ['refresh','sortApps','selectDevice','applyInfo','open','cycleDevice']) root[name]=context[name];
  return {root,context,infoProc};
}
test('reopening requests the configured default rather than the last selection',()=>{
 const {root,infoProc}=setup(); root.open('{}');
 assert.equal(root.ip,''); assert.equal(infoProc.command.at(-1),'info'); assert.equal(infoProc.command.length,2);
});
test('late results cannot undo a TV switch',()=>{
 const {root,infoProc}=setup(); infoProc.running=true; root.selectDevice('B');
 root.applyInfo(JSON.stringify({ip:'A',name:'Living'}));
 assert.equal(root.ip,'B'); assert.equal(root.deviceName,'Bedroom');
});
test('offline results keep the TV list available',()=>{
 const {root}=setup(); root.applyInfo(JSON.stringify({ip:'A',name:'Living',unreachable:true,devices:root.devices}));
 assert.equal(root.unreachable,true); assert.equal(root.devices.length,2);
});
test('Tab clears the old TV status immediately',()=>{
 const {root}=setup(); root.power='PowerOn'; root.activeApp='Netflix'; root.cycleDevice();
 assert.equal(root.ip,'B'); assert.equal(root.deviceName,'Bedroom'); assert.equal(root.power,''); assert.equal(root.activeApp,'');
});
