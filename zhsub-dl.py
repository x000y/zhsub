#!/usr/bin/env python3
"""zhsub-dl — zhsub 模型下载器 / 配置管理 [local-build]

管理三类可下载资源:
  - ASR 语言包:  en-0626(内置) | multi-8lang(324MB,8语) | multilingual-2025(全语版,需HF登录)
  - 翻译模型:   Hy-MT2-1.8B-8bit (1.8GB, 默认)

下载渠道 (channel):  每个模型可在多个源之间选择
  - hf-mirror    : https://hf-mirror.com        (国内镜像, 默认; 大文件 Xet 需代理)
  - hf-official  : https://huggingface.co       (需代理)
  - modelscope   : https://modelscope.cn        (阿里, 国内免代理直连 ★推荐)
  - custom       : 自定义 HF 兼容端点

代理 (proxy): 可选, 填 http://127.0.0.1:1088 这类地址
  zhsub-dl.py set --proxy http://127.0.0.1:1088

说明: 渠道是全局的。ModelScope 上有的模型(中英双语/Hy-MT2)切到
  modelscope 渠道即可免代理下载; 8语模型等不在 ModelScope 上的, 用
  hf-mirror + 代理 或 hf-official + 代理。

用法:
  zhsub-dl.py status
  zhsub-dl.py download --model multi-zh-hans   # 中英双语(69MB, ModelScope直连)
  zhsub-dl.py download --model Hy-MT2-1.8B-8bit
  zhsub-dl.py set --asr multi-zh-hans --channel modelscope
  zhsub-dl.py show

输出: 人类可读文本 + NDJSON 事件行 {"t":"DL","model":...,"pct":...,"file":...,"msg":...}
"""
import argparse, json, os, sys, time

# ---------------- 路径 ----------------
APP_SUPPORT = os.path.expanduser('~/Library/Application Support/zhsub')
CONFIG_PATH = os.path.join(APP_SUPPORT, 'config.json')
MODELS_DIR = os.path.join(APP_SUPPORT, 'models')
ASR_DIR = os.path.join(MODELS_DIR, 'asr')
MT_DIR = os.path.join(MODELS_DIR, 'mt')
BUILTIN_ASR_DIR = os.path.expanduser('~/zh-sub-engine/models/streaming-zipformer-en-0626')

DEFAULT_CONFIG = {
    'asr': 'en-0626',
    'mt': 'Hy-MT2-1.8B-8bit',
    'channel': 'hf-mirror',
    'custom_url': '',
    'proxy': '',
    'cache_size': 512,
    'sub_gap': 1200,
}

# ---------------- 模型清单 ----------------
# asr.files: (filename, size_bytes) 列表; 用 'auto' 表示整仓 snapshot
MANIFEST = {
    'asr': {
        'en-0626': {
            'desc': '英文专用 (内置, 零下载)',
            'size_mb': 253,
            'builtin': True,
            'dir': BUILTIN_ASR_DIR,
            'files': None,
        },
        'multi-zh-hans': {
            'desc': '中文专用 (简中, 实测英文不支持; ModelScope 免代理, 仅69MB)',
            'size_mb': 69,
            'builtin': False,
            'dir': os.path.join(ASR_DIR, 'multi-zh-hans'),
            'hf_repo': 'k2-fsa/sherpa-onnx-streaming-zipformer-multi-zh-hans-2023-12-12',
            'ms_repo': 'k2-fsa/sherpa-onnx-streaming-zipformer-multi-zh-hans-2023-12-12',
            'branch': 'main',  # HF 分支
            'files': [
                ('bpe.model', 343965),
                ('tokens.txt', 18626),
                ('decoder-epoch-20-avg-1-chunk-16-left-128.int8.onnx', 1234266),
                ('encoder-epoch-20-avg-1-chunk-16-left-128.int8.onnx', 70148185),
                ('joiner-epoch-20-avg-1-chunk-16-left-128.int8.onnx', 1068375),
            ],
        },
        'multi-8lang': {
            'desc': '多语言8语: 英/日/中/俄/泰/越/印尼/阿拉伯 (自动检测)',
            'size_mb': 324,
            'builtin': False,
            'dir': os.path.join(ASR_DIR, 'multi-8lang'),
            'hf_repo': 'csukuangfj/sherpa-onnx-streaming-zipformer-ar_en_id_ja_ru_th_vi_zh-2025-02-10',
            'ms_repo': None,
            'branch': 'main',
            'files': [
                ('bpe.model', 476049),
                ('tokens.txt', 195244),
                ('decoder-epoch-75-avg-11-chunk-16-left-128.onnx', 33837085),
                ('joiner-epoch-75-avg-11-chunk-16-left-128.int8.onnx', 8257421),
                ('encoder-epoch-75-avg-11-chunk-16-left-128.int8.onnx', 296583597),
            ],
        },
        'multilingual-2025': {
            'desc': '全语版 ~10语 (含韩语/粤语), 需 HF 账号且仓库 gated',
            'size_mb': 500,
            'builtin': False,
            'dir': os.path.join(ASR_DIR, 'multilingual-2025'),
            'hf_repo': 'csukuangfj/sherpa-onnx-streaming-zipformer-multilingual-2025-04-02',
            'ms_repo': None,
            'branch': 'main',
            'files': 'auto',
        },
    },
    'mt': {
        'Hy-MT2-1.8B-8bit': {
            'desc': 'Hy-MT2 1.8B 8bit (默认翻译; ModelScope 免代理直连)',
            'size_mb': 1800,
            'builtin': False,
            'dir': os.path.join(MT_DIR, 'Hy-MT2-1.8B-8bit'),
            'hf_repo': 'mlx-community/Hy-MT2-1.8B-8bit',
            'ms_repo': 'mlx-community/Hy-MT2-1.8B-8bit',
            'branch': 'main',
            'files': 'auto',
        },
        'Hy-MT2-1.8B-4bit': {
            'desc': 'Hy-MT2 1.8B 4bit (快近一倍/961MB; ModelScope 免代理)',
            'size_mb': 961,
            'builtin': False,
            'dir': os.path.join(MT_DIR, 'Hy-MT2-1.8B-4bit'),
            'hf_repo': 'mlx-community/Hy-MT2-1.8B-4bit',
            'ms_repo': 'mlx-community/Hy-MT2-1.8B-4bit',
            'branch': 'main',
            'files': 'auto',
        },
    },
}

# ---------------- 渠道 ----------------
def channel_base(cfg):
    ch = cfg.get('channel', 'hf-mirror')
    if ch == 'hf-official':
        return 'https://huggingface.co', 'main'
    if ch == 'modelscope':
        return 'https://modelscope.cn', 'master'
    if ch == 'custom':
        url = (cfg.get('custom_url') or '').strip()
        if not url:
            print('✗ 自定义渠道需要设置 custom_url (set --custom-url <URL>)', file=sys.stderr)
            sys.exit(1)
        return url.rstrip('/'), 'main'
    return 'https://hf-mirror.com', 'main'

# ---------------- 工具 ----------------
def load_config():
    if os.path.exists(CONFIG_PATH):
        try:
            with open(CONFIG_PATH) as f: cfg = json.load(f)
            for k, v in DEFAULT_CONFIG.items():
                cfg.setdefault(k, v)
            return cfg
        except Exception:
            pass
    return dict(DEFAULT_CONFIG)

def save_config(cfg):
    os.makedirs(APP_SUPPORT, exist_ok=True)
    with open(CONFIG_PATH, 'w') as f:
        json.dump(cfg, f, ensure_ascii=False, indent=2)

def mb(n):
    return n / 1048576

def emit_ndjson(obj):
    print(json.dumps(obj, ensure_ascii=False), flush=True)

def file_done(path, expected=None):
    """文件是否已就绪。跨渠道文件大小可能不同(HF/ModelScope 不同 commit),
    因此只要求存在且非空; 严格校验由 _stream_download 的 content-range 负责。"""
    return os.path.isfile(path) and os.path.getsize(path) > 0

def model_complete(m):
    """目录是否已完整下载。asr 检查清单文件; mt(auto) 检查 model.safetensors。"""
    d = m['dir']
    if isinstance(m.get('files'), list):
        return all(file_done(os.path.join(d, f[0])) for f in m['files'])
    # auto 整仓: 翻译模型看 model.safetensors; 其他看任意文件
    if os.path.isfile(os.path.join(d, 'model.safetensors')) and os.path.getsize(os.path.join(d, 'model.safetensors')) > 0:
        return True
    return os.path.isdir(d) and any(os.path.isfile(os.path.join(d, x)) and os.path.getsize(os.path.join(d, x)) > 0
                                    for x in os.listdir(d))

def http_client(cfg):
    import httpx
    proxy = (cfg.get('proxy') or '').strip()
    if proxy:
        return httpx.Client(proxy=proxy, follow_redirects=True, timeout=60.0)
    return httpx.Client(follow_redirects=True, timeout=60.0)

# ---------------- 命令 ----------------
def cmd_status():
    cfg = load_config()
    print('═' * 60)
    print('zhsub 模型状态    asr=%s mt=%s 渠道=%s' % (cfg['asr'], cfg['mt'], cfg['channel']))
    print('═' * 60)
    for kind, group in [('ASR 语言包', MANIFEST['asr']), ('翻译模型', MANIFEST['mt'])]:
        print(f'\n【{kind}】')
        for key, m in group.items():
            mark = '▶' if (cfg['asr'] == key or cfg['mt'] == key) else ' '
            if m.get('builtin'):
                state = '已内置'
            elif model_complete(m):
                state = '已下载'
            else:
                n_missing = 0
                if isinstance(m.get('files'), list):
                    n_missing = sum(1 for f in m['files'] if not file_done(os.path.join(m['dir'], f[0])))
                state = '未完成(%d文件缺)' % n_missing if n_missing else '未下载'
            size = f"{m['size_mb']}MB" + ('(内置)' if m.get('builtin') else '')
            print(f"  {mark} {key:<18} {state:<14} {size:<10} {m['desc']}")

def cmd_status_json():
    """机器可读状态: floater 等 UI 调用。输出单个 JSON 对象。"""
    cfg = load_config()
    models = []
    for kind, group in [('asr', MANIFEST['asr']), ('mt', MANIFEST['mt'])]:
        for key, m in group.items():
            if m.get('builtin'):
                state = 'builtin'
            elif model_complete(m):
                state = 'ready'
            else:
                n_missing = 0
                if isinstance(m.get('files'), list):
                    n_missing = sum(1 for f in m['files'] if not file_done(os.path.join(m['dir'], f[0])))
                state = 'partial' if n_missing else 'missing'
            models.append({
                'kind': kind, 'key': key, 'desc': m['desc'],
                'size_mb': m['size_mb'], 'state': state,
                'active': (cfg['asr'] == key) if kind == 'asr' else (cfg['mt'] == key),
                'on_modelscope': bool(m.get('ms_repo')),
                'has_hf': bool(m.get('hf_repo')),
            })
    print(json.dumps({'config': cfg, 'models': models}, ensure_ascii=False))

def cmd_download(model):
    cfg = load_config()
    found = None
    for group in MANIFEST.values():
        if model in group:
            found = group[model]; break
    if found is None:
        print(f'✗ 未知模型: {model}. 可用: ' + ', '.join(list(MANIFEST['asr']) + list(MANIFEST['mt'])))
        sys.exit(1)
    if found.get('builtin'):
        print('✓ 该模型是内置的, 无需下载')
        return

    base, branch = channel_base(cfg)
    # 渠道对应 repo: modelscope 用 ms_repo(若 None 提示不可用), 否则 hf_repo
    if cfg.get('channel') == 'modelscope':
        repo = found.get('ms_repo')
        if not repo:
            print(f'✗ {model} 不在 ModelScope 上。请改用渠道 hf-mirror 或 hf-official (需代理)。')
            emit_ndjson({'t': 'DL', 'model': model, 'pct': -1, 'msg': 'ModelScope 无此模型'})
            sys.exit(1)
    else:
        repo = found.get('hf_repo')
    dest = found['dir']
    files = found['files']
    os.makedirs(dest, exist_ok=True)
    client = http_client(cfg)
    print(f'▶ 下载 {model}  渠道={cfg["channel"]}  base={base}')
    print(f'  代理: {cfg.get("proxy") or "(无, 直连)"}')

    def resolve(name):
        if cfg.get('channel') == 'modelscope':
            return f'{base}/models/{repo}/resolve/{branch}/{name}'
        return f'{base}/{repo}/resolve/{branch}/{name}'

    if files == 'auto':
        # 整仓 snapshot: 先列文件再逐一下载
        # 若已有关键文件(model.safetensors 或目录非空)则跳过整个下载
        if os.path.isfile(os.path.join(dest, 'model.safetensors')) and os.path.getsize(os.path.join(dest, 'model.safetensors')) > 0:
            print('✓ 该模型已下载 (model.safetensors 存在)')
            _write_model_json(dest, found)
            return
        if cfg.get('channel') == 'modelscope':
            names = _ms_list_files(base, repo)
        else:
            print('  获取仓库文件列表 …')
            try:
                names = _hf_list_files(base, repo)
            except Exception as e:
                print(f'✗ 无法获取文件列表(仓库 gated 或网络不通): {e}')
                print('  提示: 该仓库需要 HF 账号访问, 或改用 hf-mirror 渠道 + 代理')
                emit_ndjson({'t': 'DL', 'model': model, 'pct': -1, 'msg': f'列表失败: {e}'})
                sys.exit(1)
        files = [(n, 0) for n in names if not n.endswith(('.gitattributes',))]
        total = sum(f[1] for f in files)
        done = 0
        for name, _ in files:
            fpath = os.path.join(dest, name)
            os.makedirs(os.path.dirname(fpath), exist_ok=True)
            if os.path.isfile(fpath) and os.path.getsize(fpath) > 0:
                done += 1
                emit_ndjson({'t': 'DL', 'model': model, 'pct': round(done / len(files) * 100, 1), 'msg': f'{name} 已存在'})
                continue
            emit_ndjson({'t': 'DL', 'model': model, 'msg': f'下载 {name} …'})
            ok = _stream_download(client, resolve(name), fpath, model, name,
                                  pct_base=done / len(files) * 100, pct_span=100 / len(files))
            if not ok:
                sys.exit(1)
            done += 1
            print(f'  ✓ {name}')
        _write_model_json(dest, found)
        emit_ndjson({'t': 'DL', 'model': model, 'pct': 100, 'msg': '完成'})
        print(f'✓ {model} 下载完成 → {dest}')
        return

    total = sum(f[1] for f in files)
    done = sum(f[1] for f in files if file_done(os.path.join(dest, f[0])))
    emit_ndjson({'t': 'DL', 'model': model, 'pct': round(done / total * 100, 1),
                 'msg': f'已有 {mb(done):.0f}/{mb(total):.0f}MB'})
    for fname, fsize in files:
        fpath = os.path.join(dest, fname)
        if file_done(fpath):
            emit_ndjson({'t': 'DL', 'model': model, 'pct': round(done / total * 100, 1),
                         'msg': f'{fname} 已存在, 跳过'})
            continue
        emit_ndjson({'t': 'DL', 'model': model, 'pct': round(done / total * 100, 1),
                     'msg': f'下载 {fname} ({mb(fsize):.0f}MB) …'})
        ok = _stream_download(client, resolve(fname), fpath, model, fname,
                              pct_base=done / total * 100, pct_span=fsize / total * 100)
        if not ok:
            sys.exit(1)
        if file_done(fpath):
            done += fsize
            print(f'  ✓ {fname} ({mb(fsize):.0f}MB)')
        else:
            print(f'  ⚠ {fname} 下载后为空')
            emit_ndjson({'t': 'DL', 'model': model, 'pct': -1, 'msg': f'{fname} 校验失败'})
            sys.exit(1)
    emit_ndjson({'t': 'DL', 'model': model, 'pct': 100, 'msg': '完成'})
    _write_model_json(dest, found)
    print(f'✓ {model} 下载完成 → {dest}')

# ---------------- ModelScope 辅助 ----------------
def _ms_list_files(base, repo):
    """用 ModelScope API 列仓库文件 (递归)。"""
    import httpx
    url = f'{base}/api/v1/models/{repo}/repo/files?Revision=master&Recursive=true'
    with httpx.Client(timeout=30.0) as c:
        r = c.get(url)
        r.raise_for_status()
        d = r.json()
    out = []
    for f in d.get('Data', {}).get('Files', []):
        p = f.get('Path', '')
        if f.get('Type') == 'tree':
            continue
        out.append(p)
    return out

def _hf_list_files(base, repo):
    """用 HF API 列仓库文件 (递归) — httpx 实现, 不依赖 huggingface_hub。"""
    import httpx
    url = f'{base}/api/models/{repo}/tree/main?recursive=true'
    with httpx.Client(timeout=30.0) as c:
        r = c.get(url)
        r.raise_for_status()
        d = r.json()
    out = []
    if isinstance(d, list):
        for f in d:
            if f.get('type') == 'file':
                out.append(f.get('path', ''))
    return out

def _write_model_json(dest, m):
    """写 model.json 元数据: 引擎据此加载任意 ASR 模型(文件名/分词器/分支)。"""
    meta = {'key': None, 'type': 'asr', 'files': None}
    if isinstance(m.get('files'), list):
        meta['files'] = [f[0] for f in m['files']]
    meta['type'] = 'asr' if 'bpe.model' in (m.get('files') or []) or 'tokens.txt' in str(m.get('files')) else 'mt'
    with open(os.path.join(dest, 'model.json'), 'w') as f:
        json.dump(meta, f, ensure_ascii=False, indent=2)

def _stream_download(client, url, fpath, model, fname, pct_base=0.0, pct_span=100.0):
    """流式下载 + Range 断点续传 + 大小校验。成功返回 True。
    进度基准: 优先用响应头 content-range 的总大小; 拿不到则用文件大小。"""
    existing = os.path.getsize(fpath) if os.path.isfile(fpath) else 0
    headers = {'Range': f'bytes={existing}-'} if existing > 0 else {}
    try:
        with client.stream('GET', url, headers=headers) as r:
            if r.status_code in (401, 403):
                print(f'✗ {fname}: 访问被拒 ({r.status_code})。该仓库可能 gated 或渠道不通。')
                emit_ndjson({'t': 'DL', 'model': model, 'pct': -1, 'msg': f'{fname} 403/401'})
                return False
            if r.status_code not in (200, 206):
                print(f'✗ {fname}: HTTP {r.status_code} {url[:120]}')
                emit_ndjson({'t': 'DL', 'model': model, 'pct': -1, 'msg': f'{fname} HTTP {r.status_code}'})
                return False
            # 总大小: 优先 content-range (bytes 0-0/N), 否则 content-length + 已存在
            total_len = 0
            for name, val in r.headers.items():
                if name.lower() == 'content-range':
                    total_len = int(val.split('/')[-1])
            if total_len == 0:
                total_len = int(r.headers.get('content-length', 0)) + existing
            mode = 'ab' if (existing > 0 and r.status_code == 206) else 'wb'
            with open(fpath, mode) as f:
                last_pct = -1
                for chunk in r.iter_bytes(262144):
                    f.write(chunk)
                    got = os.path.getsize(fpath)
                    pct = pct_base + pct_span * (got / total_len) if total_len else pct_base
                    if int(pct) != last_pct:
                        last_pct = int(pct)
                        emit_ndjson({'t': 'DL', 'model': model, 'pct': round(pct, 1),
                                     'msg': f'{fname} {mb(got):.0f}/{mb(total_len):.0f}MB'})
            # 校验: 若 content-range 给了总大小则严格比对
            if total_len and os.path.getsize(fpath) != total_len:
                print(f'✗ {fname} 下载不完整: {os.path.getsize(fpath)} != {total_len}')
                emit_ndjson({'t': 'DL', 'model': model, 'pct': -1, 'msg': f'{fname} 不完整'})
                return False
            return True
    except Exception as e:
        print(f'✗ {fname} 下载异常: {e}')
        emit_ndjson({'t': 'DL', 'model': model, 'pct': -1, 'msg': f'{fname} 异常: {e}'})
        return False

def cmd_set(asr, mt, channel, custom_url, proxy, cache_size, sub_gap):
    cfg = load_config()
    if asr:
        if asr not in MANIFEST['asr']:
            print(f'✗ 未知 ASR 模型: {asr}'); sys.exit(1)
        cfg['asr'] = asr
    if mt:
        if mt not in MANIFEST['mt']:
            print(f'✗ 未知翻译模型: {mt}'); sys.exit(1)
        cfg['mt'] = mt
    if channel:
        if channel not in ('hf-mirror', 'hf-official', 'modelscope', 'custom'):
            print(f'✗ 未知渠道: {channel}'); sys.exit(1)
        cfg['channel'] = channel
    if custom_url is not None:
        cfg['custom_url'] = custom_url.strip()
    if proxy is not None:
        cfg['proxy'] = proxy.strip()
    if cache_size is not None:
        try:
            cfg['cache_size'] = max(64, min(8192, int(cache_size)))
        except ValueError:
            print(f'✗ 缓存上限必须是数字: {cache_size}'); sys.exit(1)
    if sub_gap is not None:
        try:
            cfg['sub_gap'] = max(400, min(5000, int(sub_gap)))
        except ValueError:
            print(f'✗ 字幕间隔必须是数字(毫秒): {sub_gap}'); sys.exit(1)
    save_config(cfg)
    print(f'✓ 配置已保存: asr={cfg["asr"]} mt={cfg["mt"]} 渠道={cfg["channel"]} 缓存={cfg.get("cache_size")} 字幕间隔={cfg.get("sub_gap")}ms'
          + (f' 代理={cfg["proxy"]}' if cfg.get('proxy') else ' 无代理'))

def cmd_show():
    cfg = load_config()
    print(json.dumps(cfg, ensure_ascii=False, indent=2))
    print('配置路径:', CONFIG_PATH)

if __name__ == '__main__':
    ap = argparse.ArgumentParser(description='zhsub 模型下载器')
    sub = ap.add_subparsers(dest='cmd')
    p_st = sub.add_parser('status', help='查看所有模型状态')
    p_st.add_argument('--json', action='store_true', help='JSON 输出(供 UI 读取)')
    p_dl = sub.add_parser('download', help='下载模型')
    p_dl.add_argument('--model', required=True)
    p_set = sub.add_parser('set', help='设置配置')
    p_set.add_argument('--asr')
    p_set.add_argument('--mt')
    p_set.add_argument('--channel', choices=['hf-mirror', 'hf-official', 'modelscope', 'custom'])
    p_set.add_argument('--custom-url')
    p_set.add_argument('--proxy')
    p_set.add_argument('--cache-size')
    p_set.add_argument('--sub-gap')
    sub.add_parser('show', help='显示当前配置')
    a = ap.parse_args()
    if a.cmd == 'status':
        if a.json: cmd_status_json()
        else: cmd_status()
    elif a.cmd == 'download': cmd_download(a.model)
    elif a.cmd == 'set': cmd_set(a.asr, a.mt, a.channel, a.custom_url, a.proxy, a.cache_size, a.sub_gap)
    elif a.cmd == 'show': cmd_show()
    else: ap.print_help()
