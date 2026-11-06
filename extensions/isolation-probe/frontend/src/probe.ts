import { IToolbar, IToolbarBuilder, ObjectsViewContext, IInitializable, InjectionSource, ICommandBuilderProvider } from '@pilotdev/pilot-web-sdk';
import { MARKER, COLOR } from './build';
export class IsolationProbe extends IToolbar<ObjectsViewContext> implements IInitializable {
 private commands!: ICommandBuilderProvider;
 initialize(source: InjectionSource): void { this.commands = source.commandBuilderProvider; }
 build(builder: IToolbarBuilder, context: ObjectsViewContext): void {
  builder.addButtonItem('isolation-probe',builder.count).withHeader(`Isolation Probe ${MARKER}`).withIsEnabled(true).withHint('Read the loaded backend code, without changing database data');
 }
 onToolbarItemClick(name: string): void { if(name==='isolation-probe') this.show(); }
 private show(): void {
  document.getElementById('isolation-probe-panel')?.remove();
  const panel=document.createElement('section');panel.id='isolation-probe-panel';panel.setAttribute('aria-label','Isolation Probe');
  Object.assign(panel.style,{position:'fixed',top:'90px',right:'24px',width:'540px',maxWidth:'90vw',maxHeight:'80vh',overflow:'auto',zIndex:'10000',background:'#ffffff',color:'#111827',border:`4px solid ${COLOR}`,borderRadius:'12px',padding:'20px',boxShadow:'0 8px 32px #0005',font:'15px system-ui'});
  const title=document.createElement('h2');title.textContent=`Isolation Probe — Frontend ${MARKER}`;panel.append(title);
  const origin=document.createElement('p');origin.textContent=`Environment: ${location.origin}`;panel.append(origin);
  const refresh=document.createElement('button');refresh.textContent='Refresh backend status';refresh.type='button';panel.append(refresh);
  const close=document.createElement('button');close.textContent='Close probe';close.type='button';close.style.marginLeft='12px';close.onclick=()=>panel.remove();panel.append(close);
  const output=document.createElement('pre');output.id='isolation-probe-result';output.style.whiteSpace='pre-wrap';output.style.wordBreak='break-word';panel.append(output);document.body.append(panel);
  const read=()=>{const nonce=crypto.randomUUID();output.textContent='Loading backend...';this.commands.newCommandBuilder().command('IsolationProbeStatus').arg('nonce',nonce).invoke<string>().subscribe({next:(value)=>{try{const data=JSON.parse(value);if(data.nonce!==nonce)throw new Error('Nonce mismatch: response is stale');output.textContent=JSON.stringify({frontendVersion:MARKER,origin:location.origin,...data},null,2);}catch(error){output.textContent=`Invalid response: ${error}`;}},error:(error)=>{output.textContent=`Backend error: ${error?.message||String(error)}`;}});};
  refresh.onclick=read;read();
 }
}
