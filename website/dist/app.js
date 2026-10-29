'use strict';
const state = { mode: 'noise', ambient: 12, eq: [0, 0, 0, 0, 0, 0] };
const descriptions = {
  noise: 'Noise canceling for deep work. Ambient sound for everything around you. Move between them in a click.',
  eq: 'Five bands and Clear Bass put the finishing touch on your sound. Try a curve, then make it yours.',
  scenes: 'Your favorite settings, together. The Mac app can apply scenes manually, on connection, on a schedule, or when an app opens.'
};
const names = { noise: 'Noise canceling', ambient: 'Ambient sound', off: 'Noise control off' };
const result = message => { document.getElementById('demo-result').textContent = message; };
function setMode(mode, announce = true) {
  state.mode = mode;
  document.querySelectorAll('[data-mode]').forEach(button => {
    const active = button.dataset.mode === mode;
    button.classList.toggle('selected', active); button.setAttribute('aria-pressed', String(active));
  });
  document.getElementById('mode-label').textContent = names[mode];
  document.getElementById('hero-mode').textContent = {noise:'Your world, turned down.',ambient:'A little more of the outside.',off:'Just you and your music.'}[mode];
  if (announce) result(`Preview: ${names[mode]}${mode === 'ambient' ? ` · level ${state.ambient}` : ''}.`);
}
function setTab(name, focus = false) {
  document.querySelectorAll('[data-tab]').forEach(button => {
    const active = button.dataset.tab === name;
    button.setAttribute('aria-selected', String(active)); button.tabIndex = active ? 0 : -1;
    if (active && focus) button.focus();
  });
  ['noise','eq','scenes'].forEach(tab => { document.getElementById(`demo-${tab}`).hidden = tab !== name; });
  document.getElementById('demo-description').textContent = descriptions[name];
}
document.querySelectorAll('[data-mode]').forEach(button => button.addEventListener('click', () => setMode(button.dataset.mode)));
document.querySelectorAll('[data-tab]').forEach(button => {
  button.addEventListener('click', () => setTab(button.dataset.tab));
  button.addEventListener('keydown', event => {
    const tabs = ['noise','eq','scenes']; let index = tabs.indexOf(button.dataset.tab);
    if (['ArrowRight','ArrowDown'].includes(event.key)) index = (index + 1) % 3;
    else if (['ArrowLeft','ArrowUp'].includes(event.key)) index = (index + 2) % 3;
    else if (event.key === 'Home') index = 0;
    else if (event.key === 'End') index = 2;
    else return;
    event.preventDefault(); setTab(tabs[index], true);
  });
});
document.getElementById('ambient').addEventListener('input', event => {
  state.ambient = Number(event.target.value); document.getElementById('ambient-value').value = state.ambient; setMode('ambient');
});
const labels = ['Bass', '400', '1k', '2.5k', '6.3k', '16k'];
const bandHost = document.getElementById('eq-bands');
labels.forEach((label, index) => {
  const wrapper = document.createElement('label'); wrapper.htmlFor = `band-${index}`;
  const value = document.createElement('output'); value.id = `band-value-${index}`; value.value = '0'; value.htmlFor = `band-${index}`;
  const input = document.createElement('input'); Object.assign(input, { type:'range', min:'-10', max:'10', value:'0', id:`band-${index}` });
  input.setAttribute('aria-label', index === 0 ? 'Clear Bass' : `${label} hertz equalizer`);
  input.addEventListener('input', () => { state.eq[index] = Number(input.value); renderEQ('custom'); result('Preview: custom equalizer curve.'); });
  const name = document.createElement('span'); name.textContent = label;
  wrapper.append(value,input,name); bandHost.append(wrapper);
});
function renderEQ(preset) {
  state.eq.forEach((value,index) => { document.getElementById(`band-${index}`).value = value; document.getElementById(`band-value-${index}`).value = value > 0 ? `+${value}` : String(value); });
  document.querySelectorAll('[data-preset]').forEach(button => { const active=button.dataset.preset===preset; button.classList.toggle('selected',active); button.setAttribute('aria-pressed',String(active)); });
}
function setPreset(preset, announce = true) {
  state.eq = {balanced:[0,0,0,0,0,0], warm:[4,3,1,0,-1,-2], vocal:[-1,-2,0,4,2,0]}[preset].slice();
  renderEQ(preset); if(announce) result(`Preview: ${preset} equalizer curve.`);
}
document.querySelectorAll('[data-preset]').forEach(button=>button.addEventListener('click',()=>setPreset(button.dataset.preset)));
document.getElementById('reset-eq').addEventListener('click',()=>setPreset('balanced'));
document.querySelectorAll('[data-scene]').forEach(button=>button.addEventListener('click',()=>{
  const scene = {focus:{mode:'noise',level:12,eq:'balanced',name:'Deep focus'},outside:{mode:'ambient',level:12,eq:'warm',name:'Out & about'},conversation:{mode:'ambient',level:20,eq:'vocal',name:'Conversation'}}[button.dataset.scene];
  state.ambient=scene.level; document.getElementById('ambient').value=scene.level; document.getElementById('ambient-value').value=scene.level;
  setMode(scene.mode,false); setPreset(scene.eq,false);
  document.querySelectorAll('[data-scene] b').forEach(label=>{label.textContent='Apply ↗';});
  button.querySelector('b').textContent='Applied ✓'; result(`Preview: ${scene.name} applied. ${names[scene.mode]}, ${scene.eq} EQ.`);
}));
