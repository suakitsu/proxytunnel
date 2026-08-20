const PRODUCT_NAME = "ProxyTunnel Edge";

const baseStyles = String.raw`
:root{color-scheme:dark;--bg:#0b1117;--panel:#111a22;--panel2:#17232d;--line:#263744;--text:#e7eef4;--muted:#94a6b5;--accent:#35c7a1;--danger:#ff6b7a;--warning:#f7c35f;font-family:Inter,"Segoe UI","Microsoft YaHei",system-ui,sans-serif}
*{box-sizing:border-box}body{margin:0;min-height:100vh;background:radial-gradient(circle at 20% 0,#14252d 0,transparent 38%),var(--bg);color:var(--text)}
main{width:min(1080px,calc(100% - 32px));margin:0 auto;padding:42px 0 64px}.shell{border:1px solid var(--line);border-radius:18px;background:rgba(17,26,34,.94);box-shadow:0 24px 60px rgba(0,0,0,.28);overflow:hidden}
header{display:flex;align-items:center;justify-content:space-between;gap:18px;padding:20px 24px;border-bottom:1px solid var(--line)}.brand{display:flex;align-items:center;gap:12px}.mark{display:grid;place-items:center;width:36px;height:36px;border-radius:11px;background:linear-gradient(135deg,#35c7a1,#278ad8);font-weight:800;color:#06110e}.eyebrow{font-size:12px;letter-spacing:.12em;color:var(--accent);text-transform:uppercase}.title{font-size:20px;font-weight:700}.muted{color:var(--muted)}
.content{padding:24px}.grid{display:grid;grid-template-columns:1fr 1fr;gap:18px}.card{padding:20px;border:1px solid var(--line);border-radius:14px;background:var(--panel2)}.card h2{margin:0 0 8px;font-size:17px}.card p{margin:0 0 16px;line-height:1.65}.span2{grid-column:1/-1}
label{display:block;margin:0 0 8px;font-size:13px;color:var(--muted)}input,textarea{width:100%;border:1px solid #344957;border-radius:10px;background:#0b131a;color:var(--text);padding:12px 13px;font:inherit;outline:none}input:focus,textarea:focus{border-color:var(--accent);box-shadow:0 0 0 3px rgba(53,199,161,.12)}textarea{min-height:340px;resize:vertical;font-family:"Cascadia Code",Consolas,monospace;font-size:13px;line-height:1.55}.small-area{min-height:180px}
.actions{display:flex;flex-wrap:wrap;gap:10px;margin-top:14px}button,.button{appearance:none;border:1px solid var(--line);border-radius:10px;padding:10px 15px;background:#1a2934;color:var(--text);font:inherit;font-weight:650;cursor:pointer;text-decoration:none}button:hover,.button:hover{border-color:#4e6879}.primary{border-color:transparent;background:var(--accent);color:#062019}.danger{color:#ffdce0;border-color:#5b3038;background:#2c171c}button:disabled{opacity:.55;cursor:wait}
.notice{padding:12px 14px;border-radius:10px;background:#0c181d;border-left:3px solid var(--accent);line-height:1.55}.notice.warning{border-color:var(--warning)}.status{min-height:22px;margin-top:12px;color:var(--muted)}.status.ok{color:var(--accent)}.status.error{color:var(--danger)}
.login{width:min(460px,calc(100% - 32px));margin:10vh auto 0}.login .content{padding:28px}.login h1{margin:0 0 8px;font-size:25px}.login form{margin-top:24px}
code{font-family:"Cascadia Code",Consolas,monospace;color:#b8eadd}@media(max-width:760px){main{width:min(100% - 20px,1080px);padding-top:20px}.grid{grid-template-columns:1fr}.span2{grid-column:auto}header{align-items:flex-start;padding:17px}.content{padding:16px}.actions>*{flex:1;text-align:center}textarea{min-height:280px}}
`;

function secureHeaders(nonce) {
  return {
    "Content-Type": "text/html; charset=utf-8",
    "Cache-Control": "no-store",
    "Content-Security-Policy": `default-src 'none'; style-src 'nonce-${nonce}'; script-src 'nonce-${nonce}'; connect-src 'self'; img-src 'self' data:; base-uri 'none'; form-action 'self'; frame-ancestors 'none'`,
    "Referrer-Policy": "no-referrer",
    "X-Content-Type-Options": "nosniff",
    "X-Frame-Options": "DENY",
  };
}

function page(title, body, script = "", status = 200) {
  const nonce = crypto.randomUUID().replaceAll("-", "");
  const html = `<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="color-scheme" content="dark"><title>${title} · ${PRODUCT_NAME}</title><style nonce="${nonce}">${baseStyles}</style></head><body>${body}${script ? `<script nonce="${nonce}">${script}</script>` : ""}</body></html>`;
  return new Response(html, { status, headers: secureHeaders(nonce) });
}

function loginPage() {
  const body = `<main class="login"><section class="shell"><header><div class="brand"><div class="mark">PT</div><div><div class="eyebrow">Local admin</div><div class="title">${PRODUCT_NAME}</div></div></div></header><div class="content"><h1>管理登录</h1><p class="muted">使用部署时设置的 <code>ADMIN</code> Secret。凭据只提交到当前 Worker。</p><form id="login-form"><label for="password">管理员密码</label><input id="password" name="password" type="password" autocomplete="current-password" required autofocus><div class="actions"><button class="primary" id="submit" type="submit">登录</button></div><div class="status" id="status" role="status"></div></form></div></section></main>`;
  const script = String.raw`
const form=document.getElementById('login-form'),button=document.getElementById('submit'),status=document.getElementById('status');
form.addEventListener('submit',async(event)=>{event.preventDefault();button.disabled=true;status.className='status';status.textContent='正在验证…';try{const body=new URLSearchParams(new FormData(form));const response=await fetch('/login',{method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded;charset=UTF-8'},body});if(!response.ok)throw new Error('密码不正确');const result=await response.json();if(!result.success)throw new Error('登录失败');location.replace('/admin');}catch(error){status.className='status error';status.textContent=error.message||'登录失败';button.disabled=false;}});
`;
  return page("管理登录", body, script);
}

function adminPage() {
  const body = `<main><section class="shell"><header><div class="brand"><div class="mark">PT</div><div><div class="eyebrow">Pinned & self-hosted</div><div class="title">EdgeTunnel 配置</div></div></div><a class="button" href="/logout">退出</a></header><div class="content"><div class="notice">本页面随 ProxyTunnel 源码发布，不会从第三方站点动态加载。所有保存动作只写入当前 Worker 的 <code>KV</code>。</div><div class="grid" style="margin-top:18px"><section class="card span2"><h2>核心配置</h2><p class="muted">完整配置使用 JSON 编辑，既保留上游全部字段，也避免管理页面悄悄上传账户凭据。</p><label for="config">config.json</label><textarea id="config" spellcheck="false" aria-label="EdgeTunnel JSON configuration"></textarea><div class="actions"><button id="reload">重新读取</button><button class="primary" id="save-config">校验并保存</button><button class="danger" id="reset">恢复默认配置</button></div><div class="status" id="config-status" role="status"></div></section><section class="card"><h2>自定义优选节点</h2><p class="muted">每行一个地址，格式沿用 EdgeTunnel 的 <code>ADD.txt</code>。</p><textarea class="small-area" id="addresses" spellcheck="false" aria-label="Custom preferred addresses"></textarea><div class="actions"><button class="primary" id="save-addresses">保存节点</button></div><div class="status" id="address-status" role="status"></div></section><section class="card"><h2>安全边界</h2><p class="muted">Cloudflare Global API Key / API Token 的录入与用量代查已停用。请在 Cloudflare Dashboard 或 Wrangler 中查看用量和管理账户，避免高权限凭据进入 Worker URL、日志或 KV。</p><div class="notice warning">升级上游后请先运行 <code>npm run build:worker</code>。补丁锚点不一致时构建会停止，不会静默回退到远程管理页。</div></section></div></div></section></main>`;
  const script = String.raw`
const byId=(id)=>document.getElementById(id);const setStatus=(id,message,type='')=>{const node=byId(id);node.className='status '+type;node.textContent=message;};
async function request(path,options={}){const response=await fetch(path,options);const text=await response.text();if(!response.ok){let message=text;try{message=JSON.parse(text).error||JSON.parse(text).message||text;}catch{}throw new Error(message||('请求失败 '+response.status));}return text;}
async function load(){setStatus('config-status','正在读取…');try{const [config,addresses]=await Promise.all([request('/admin/config.json'),request('/admin/ADD.txt')]);byId('config').value=JSON.stringify(JSON.parse(config),null,2);byId('addresses').value=addresses==='null'?'':addresses;setStatus('config-status','配置已载入','ok');setStatus('address-status','节点列表已载入','ok');}catch(error){setStatus('config-status',error.message,'error');}}
byId('reload').addEventListener('click',load);
byId('save-config').addEventListener('click',async()=>{try{const value=JSON.parse(byId('config').value);setStatus('config-status','正在保存…');await request('/admin/config.json',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(value)});setStatus('config-status','配置已保存','ok');await load();}catch(error){setStatus('config-status',error.message,'error');}});
byId('reset').addEventListener('click',async()=>{if(!confirm('确认恢复 EdgeTunnel 默认配置？当前 config.json 会被覆盖。'))return;try{setStatus('config-status','正在恢复…');const value=await request('/admin/init');byId('config').value=JSON.stringify(JSON.parse(value),null,2);setStatus('config-status','已恢复默认配置','ok');}catch(error){setStatus('config-status',error.message,'error');}});
byId('save-addresses').addEventListener('click',async()=>{try{setStatus('address-status','正在保存…');await request('/admin/ADD.txt',{method:'POST',headers:{'Content-Type':'text/plain;charset=UTF-8'},body:byId('addresses').value});setStatus('address-status','节点列表已保存','ok');}catch(error){setStatus('address-status',error.message,'error');}});load();
`;
  return page("EdgeTunnel 配置", body, script);
}

function missingConfigurationPage(kind) {
  const isAdmin = kind === "noADMIN";
  const title = isAdmin ? "缺少 ADMIN Secret" : "缺少 KV 绑定";
  const hint = isAdmin
    ? "请使用 Wrangler Secret 或 Cloudflare Dashboard 设置 ADMIN，不要把密码写入仓库。"
    : "请把名为 KV 的 Workers KV 命名空间绑定到 Worker。";
  const body = `<main class="login"><section class="shell"><header><div class="brand"><div class="mark">PT</div><div class="title">${PRODUCT_NAME}</div></div></header><div class="content"><h1>${title}</h1><p class="muted">${hint}</p><div class="notice warning">服务拒绝使用不完整配置启动管理面板。</div></div></section></main>`;
  return page(title, body, "", 503);
}

export function serveLocalPage(kind) {
  if (kind === "login") return loginPage();
  if (kind === "admin") return adminPage();
  if (kind === "noADMIN" || kind === "noKV") return missingConfigurationPage(kind);
  return page("Not found", "<main><p>Not found</p></main>", "", 404);
}
