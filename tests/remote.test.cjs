const {readFileSync} = require('node:fs');
const vm = require('node:vm');
const test = require('node:test');
const assert = require('node:assert/strict');
const qml = readFileSync(new URL('../Remote.qml', `file://${__filename}`), 'utf8');
function setup() {
  const root = {opened: true, generation: 1, infoGeneration: 1, ip: 'A', devices: [{ip:'A',name:'Living'}, {ip:'B',name:'Bedroom'}], apps: [], pinned: [], fallbackApps: []};
  const infoProc = {running:false};
  const context = vm.createContext({root, infoProc, yodelProc:{running:false}, scanProc:{running:false}, shortcutProc:{running:false}, Qt:{callLater:fn=>fn()}, keyCatcher:{forceActiveFocus(){}}, XMLHttpRequest: function() {}});
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
test('late authenticated control replies do not update another TV',()=>{
 const {root,context}=setup();
 let called=false;
 root.bridgePending={one:{generation:0,done:()=>called=true}};
 context.applyControl(JSON.stringify({id:'one',status:200,transport:'ecp-2'}));
 assert.equal(called,false); assert.equal(root.bridgePending.one,undefined);
});
test('authenticated controls clear a prior restricted status',()=>{
 const {root,context}=setup();
 root.limited=true; root.unreachable=true;
 root.bridgePending={one:{generation:1}};
 context.applyControl(JSON.stringify({id:'one',status:200,transport:'ecp-2'}));
 assert.equal(root.limited,false); assert.equal(root.unreachable,false);
 assert.equal(root.controlTransport,'ecp-2');
});
test('Yodel Nuke dispatches the network-wide command and ignores repeated clicks',()=>{
 const {root,context}=setup(); root.rokuBin='/test/roku';
 context.startYodel(false);
 assert.deepEqual(Array.from(context.yodelProc.command), ['/test/roku','yodel-nuke','--json']);
 assert.equal(context.yodelProc.running,true);
 assert.equal(root.showingYodel,true);
 root.yodelLog='existing progress';
 context.startYodel(false);
 assert.equal(root.yodelLog,'existing progress');
});
test('Yodel Nuke keeps restoration failures available across device switches',()=>{
 const {root,context}=setup(); root.yodelLog='';
 context.applyYodel(JSON.stringify({name:'TV',status:'error',message:'Restoration incomplete; run roku yodel-restore'}));
 root.selectDevice('B');
 assert.equal(root.yodelRecoveryNeeded,true);
 assert.match(root.yodelLog,/TV: Restoration incomplete/);
 context.startYodel(true);
 assert.equal(context.yodelProc.command[1],'yodel-restore');
});
