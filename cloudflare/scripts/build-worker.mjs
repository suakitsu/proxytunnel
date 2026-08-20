import { mkdir, readFile, writeFile } from "node:fs/promises";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const cloudflareRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const projectRoot = resolve(cloudflareRoot, "..");
const upstreamPath = resolve(projectRoot, "third_party/edgetunnel/_worker.js");
const outputPath = resolve(cloudflareRoot, "worker/generated/edgetunnel.js");

let source = (await readFile(upstreamPath, "utf8")).replaceAll("\r\n", "\n");

function replaceOnce(before, after, label) {
  const first = source.indexOf(before);
  const second = first < 0 ? -1 : source.indexOf(before, first + before.length);
  if (first < 0 || second >= 0) {
    throw new Error(`Worker patch '${label}' expected exactly one upstream anchor`);
  }
  source = source.slice(0, first) + after + source.slice(first + before.length);
}

replaceOnce(
  `const Version = '2026-08-11 14:45:22';
let config_JSON, 缓存SOCKS5白名单 = null, 调试日志打印 = false;
let SOCKS5白名单 = ['*tapecontent.net', '*cloudatacdn.com', '*loadshare.org', '*cdn-centaurus.com', 'scholar.google.com'];
const Pages静态页面 = 'https://edt-pages.github.io';`,
  `import { AsyncLocalStorage } from "node:async_hooks";
import { serveLocalPage } from "../admin-ui.js";

const Version = '2026-08-11 14:45:22';
const 默认SOCKS5白名单 = Object.freeze(['*tapecontent.net', '*cloudatacdn.com', '*loadshare.org', '*cdn-centaurus.com', 'scholar.google.com']);
const 请求状态存储 = new AsyncLocalStorage();
const 默认请求状态 = Object.freeze({
	SOCKS5白名单: 默认SOCKS5白名单,
	调试日志打印: false,
	TCP并发拨号数: 2,
	反代并发拨号数: 1,
	预加载竞速拨号: false,
});
function 当前请求状态() {
	return 请求状态存储.getStore() || 默认请求状态;
}`,
  "module state",
);

replaceOnce(
  `let TCP并发拨号数 = 2, 反代并发拨号数 = 1, 预加载竞速拨号 = false;`,
  `// Request tuning lives in AsyncLocalStorage; isolates may handle overlapping requests.`,
  "dial globals",
);

replaceOnce(
  `		const 访问路径 = url.pathname.slice(1).toLowerCase();`,
  `		const 访问路径 = url.pathname.slice(1).toLowerCase();
		let config_JSON;
		const 请求状态 = {
			SOCKS5白名单: env.GO2SOCKS5
				? [...new Set(默认SOCKS5白名单.concat(await 整理成数组(env.GO2SOCKS5)))]
				: [...默认SOCKS5白名单],
			调试日志打印: ['1', 'true'].includes(env.DEBUG),
			预加载竞速拨号: ['1', 'true'].includes(env.PRELOAD_RACE_DIAL),
			反代并发拨号数: Math.max(1, Number(env.PROXY_CONCURRENT_DIAL) || 1),
			TCP并发拨号数: Math.max(1, Number(env.TCP_CONCURRENT_DIAL) || 2),
		};
		if (!env.TCP_CONCURRENT_DIAL && 请求状态.TCP并发拨号数 !== 1 && 识别运营商(request) === 'cmcc') 请求状态.TCP并发拨号数 = 1;
		return 请求状态存储.run(请求状态, async () => {`,
  "request state start",
);

replaceOnce(
  `		调试日志打印 = ['1', 'true'].includes(env.DEBUG) || 调试日志打印;
		预加载竞速拨号 = ['1', 'true'].includes(env.PRELOAD_RACE_DIAL) || 预加载竞速拨号;
		反代并发拨号数 = Math.max(1, Number(env.PROXY_CONCURRENT_DIAL) || 反代并发拨号数);
		TCP并发拨号数 = Math.max(1, Number(env.TCP_CONCURRENT_DIAL) || TCP并发拨号数);
		if (!env.TCP_CONCURRENT_DIAL && TCP并发拨号数 !== 1 && 识别运营商(request) === 'cmcc') TCP并发拨号数 = 1;
`,
  ``,
  "request global assignments",
);

replaceOnce(
  `		if (缓存SOCKS5白名单 === null) {
			if (env.GO2SOCKS5) SOCKS5白名单 = [...new Set(SOCKS5白名单.concat(await 整理成数组(env.GO2SOCKS5)))];
			缓存SOCKS5白名单 = SOCKS5白名单;
		} else SOCKS5白名单 = 缓存SOCKS5白名单;
`,
  ``,
  "SOCKS allowlist cache",
);

for (const [before, after, label] of [
  ["return fetch(Pages静态页面 + '/login');", "return serveLocalPage('login');", "login page"],
  ["return fetch(Pages静态页面 + '/admin' + url.search);", "return serveLocalPage('admin');", "admin page"],
  ["if (!预加载竞速拨号 || isIPHostname(address))", "if (!当前请求状态().预加载竞速拨号 || isIPHostname(address))", "preload state"],
  ["Math.max(1, TCP并发拨号数 | 0)", "Math.max(1, 当前请求状态().TCP并发拨号数 | 0)", "TCP dial limit"],
  ["Array.from({ length: TCP并发拨号数 }", "Array.from({ length: 当前请求状态().TCP并发拨号数 }", "TCP candidate count"],
  ["Math.floor(Number(反代并发拨号数) || 1)", "Math.floor(Number(当前请求状态().反代并发拨号数) || 1)", "proxy dial limit"],
  ["SOCKS5白名单.some(p =>", "当前请求状态().SOCKS5白名单.some(p =>", "SOCKS allowlist use"],
  ["if (调试日志打印) console.log(...args);", "if (当前请求状态().调试日志打印) console.log(...args);", "debug state"],
  ["白名单: SOCKS5白名单,", "白名单: 当前请求状态().SOCKS5白名单,", "config allowlist"],
  ["async function 读取config_JSON(env, hostname, userID, UA = \"Mozilla/5.0\", 重置配置 = false) {", "async function 读取config_JSON(env, hostname, userID, UA = \"Mozilla/5.0\", 重置配置 = false) {\n\tlet config_JSON;", "config local"],
]) replaceOnce(before, after, label);

replaceOnce(
  `if (!管理员密码) return fetch(Pages静态页面 + '/noADMIN').then(r => { const headers = new Headers(r.headers); headers.set('Cache-Control', 'no-store, no-cache, must-revalidate, proxy-revalidate'); headers.set('Pragma', 'no-cache'); headers.set('Expires', '0'); return new Response(r.body, { status: 404, statusText: r.statusText, headers }) });`,
  `if (!管理员密码) return serveLocalPage('noADMIN');`,
  "missing ADMIN page",
);

replaceOnce(
  `} else if (!envUUID) return fetch(Pages静态页面 + '/noKV').then(r => { const headers = new Headers(r.headers); headers.set('Cache-Control', 'no-store, no-cache, must-revalidate, proxy-revalidate'); headers.set('Pragma', 'no-cache'); headers.set('Expires', '0'); return new Response(r.body, { status: 404, statusText: r.statusText, headers }) });`,
  `} else if (!envUUID) return serveLocalPage('noKV');`,
  "missing KV page",
);

replaceOnce(
  `					// 没有cookie或cookie错误，跳转到/login页面
					if (!authCookie || authCookie !== await MD5MD5(UA + 加密秘钥 + 管理员密码)) return new Response('重定向中...', { status: 302, headers: { 'Location': '/login' } });`,
  `					// 没有cookie或cookie错误，跳转到/login页面
					if (!authCookie || authCookie !== await MD5MD5(UA + 加密秘钥 + 管理员密码)) return new Response('重定向中...', { status: 302, headers: { 'Location': '/login' } });
					if (访问路径 === 'admin/getcloudflareusage' || 访问路径 === 'admin/cf.json') {
						return Response.json({ error: 'Cloudflare account credentials are disabled in ProxyTunnel. Use the Cloudflare Dashboard or Wrangler.' }, { status: 410, headers: { 'Cache-Control': 'no-store' } });
					}`,
  "credential endpoint guard",
);

replaceOnce(
  `const Usage_JSON = await getCloudflareUsage(url.searchParams.get('Email'), url.searchParams.get('GlobalAPIKey'), url.searchParams.get('AccountID'), url.searchParams.get('APIToken'));`,
  `const Usage_JSON = { success: false, error: 'Cloudflare account credential lookup is disabled' };`,
  "credential query removal",
);

replaceOnce(
  `CF_JSON.GlobalAPIKey = newConfig.GlobalAPIKey;`,
  `CF_JSON.GlobalAPIKey = null;`,
  "global API key storage removal",
);

replaceOnce(
  `CF_JSON.APIToken = newConfig.APIToken;`,
  `CF_JSON.APIToken = null;`,
  "API token storage removal",
);

replaceOnce(
  `	const 初始化CF_JSON = { Email: null, GlobalAPIKey: null, AccountID: null, APIToken: null, UsageAPI: null };
	config_JSON.CF = { ...初始化CF_JSON, Usage: { success: false, pages: 0, workers: 0, total: 0, max: 100000 } };
	try {
		const CF_TXT = await env.KV.get('cf.json');
		if (!CF_TXT) {
			await env.KV.put('cf.json', JSON.stringify(初始化CF_JSON, null, 2));
		} else {
			const CF_JSON = JSON.parse(CF_TXT);
			if (CF_JSON.UsageAPI) {
				try {
					const response = await fetch(CF_JSON.UsageAPI);
					const Usage = await response.json();
					config_JSON.CF.Usage = Usage;
				} catch (err) {
					console.error(\`请求 CF_JSON.UsageAPI 失败: \${err.message}\`);
				}
			} else {
				config_JSON.CF.Email = CF_JSON.Email ? CF_JSON.Email : null;
				config_JSON.CF.GlobalAPIKey = CF_JSON.GlobalAPIKey ? 掩码敏感信息(CF_JSON.GlobalAPIKey) : null;
				config_JSON.CF.AccountID = CF_JSON.AccountID ? 掩码敏感信息(CF_JSON.AccountID) : null;
				config_JSON.CF.APIToken = CF_JSON.APIToken ? 掩码敏感信息(CF_JSON.APIToken) : null;
				config_JSON.CF.UsageAPI = null;
				const Usage = await getCloudflareUsage(CF_JSON.Email, CF_JSON.GlobalAPIKey, CF_JSON.AccountID, CF_JSON.APIToken);
				config_JSON.CF.Usage = Usage;
			}
		}
	} catch (error) {
		console.error(\`读取cf.json出错: \${error.message}\`);
	}
`,
  `	const 初始化CF_JSON = { Email: null, GlobalAPIKey: null, AccountID: null, APIToken: null, UsageAPI: null };
	config_JSON.CF = { ...初始化CF_JSON, Usage: { success: false, pages: 0, workers: 0, total: 0, max: 100000 } };
`,
  "Cloudflare credentials persistence",
);

replaceOnce(
  `		return new Response(await nginx(), { status: 200, headers: { 'Content-Type': 'text/html; charset=UTF-8' } });
	}
};`,
  `		return new Response(await nginx(), { status: 200, headers: { 'Content-Type': 'text/html; charset=UTF-8' } });
		});
	}
};`,
  "request state end",
);

const forbidden = [
  "Pages静态页面",
  "let config_JSON,",
  "缓存SOCKS5白名单",
  "GlobalAPIKey = newConfig.GlobalAPIKey",
  "APIToken = newConfig.APIToken",
];
for (const token of forbidden) {
  if (source.includes(token)) throw new Error(`Unsafe upstream token remains after patch: ${token}`);
}

await mkdir(dirname(outputPath), { recursive: true });
const generated = `// Generated by cloudflare/scripts/build-worker.mjs; do not edit.\n${source}`;
let existing = "";
try { existing = await readFile(outputPath, "utf8"); } catch {}
if (existing === generated) {
  console.log(`Worker output is current: ${outputPath}`);
} else {
  await writeFile(outputPath, generated, "utf8");
  console.log(`Generated ${outputPath}`);
}
