#!/usr/bin/env python3
"""zhsub — World Monitor 内嵌「AI 字幕」引擎
流式 ASR (sherpa-onnx zipformer) + 本地翻译 (mlx-lm Hy-MT2) + LRU 缓存
输出 NDJSON 事件行到 stdout:
  {"t":"P","ms":<音频毫秒>,"text":"英文部分结果"}
  {"t":"F","ms":...,"text":"英文定稿"}
  {"t":"Z","ms":...,"text":"英文","zh":"中文"}
用法:
  zhsub.py --file sample.wav            # 文件测试
  zhsub.py --live --pid 1234            # 实时捕获指定应用音频
"""
import argparse, json, os, re, sys, threading, time
from collections import OrderedDict
import numpy as np

LANGS = {
    'zh-cn': 'Simplified Chinese', 'zh-tw': 'Traditional Chinese',
    'ja-jp': 'Japanese', 'ko-kr': 'Korean',
}

BASE = os.path.expanduser('~/zh-sub-engine')
SR = 16000
CHUNK = SR // 10  # 100ms
PARTIAL_MIN_INTERVAL_S = 0.35

# ---------------- 配置 (~/Library/Application Support/zhsub/config.json) ----------------
APP_SUPPORT = os.path.expanduser('~/Library/Application Support/zhsub')
CONFIG_PATH = os.path.join(APP_SUPPORT, 'config.json')
DEFAULT_CONFIG = {'asr': 'en-0626', 'mt': 'Hy-MT2-1.8B-8bit', 'channel': 'hf-mirror', 'custom_url': '', 'proxy': ''}

def load_config():
    if os.path.exists(CONFIG_PATH):
        try:
            with open(CONFIG_PATH) as f: cfg = json.load(f)
            for k, v in DEFAULT_CONFIG.items(): cfg.setdefault(k, v)
            return cfg
        except Exception:
            pass
    return dict(DEFAULT_CONFIG)

def resolve_asr_dir(cfg):
    """根据配置返回 ASR 模型目录。en-0626 优先内置, 否则用下载目录。"""
    key = cfg.get('asr', 'en-0626')
    if key == 'en-0626':
        builtin = f'{BASE}/models/streaming-zipformer-en-0626'
        if os.path.isdir(builtin):
            return builtin
        return os.path.join(APP_SUPPORT, 'models', 'asr', 'en-0626')
    return os.path.join(APP_SUPPORT, 'models', 'asr', key)

def make_recognizer():
    import sherpa_onnx
    import glob
    cfg = load_config()
    mdir = resolve_asr_dir(cfg)
    tokens = f'{mdir}/tokens.txt'
    bpe = f'{mdir}/bpe.model'
    # 自动探测 onnx 文件: 优先 int8 量化版 encoder/joiner, 其余任意
    def pick(prefix, prefer_int8=True):
        cands = glob.glob(f'{mdir}/{prefix}*.onnx')
        if prefer_int8:
            int8 = [c for c in cands if '.int8.' in c]
            if int8: return int8[0]
        return cands[0] if cands else None
    enc = pick('encoder-epoch')
    dec = pick('decoder-epoch', prefer_int8=False)
    joi = pick('joiner-epoch')
    if not (enc and dec and joi):
        print(f'[zhsub] ✗ ASR 模型未下载: {cfg.get("asr")} (目录 {mdir})', file=sys.stderr, flush=True)
        print(f'[zhsub] 请在设置面板 → 识别模型 → 下载, 或运行: zhsub-dl.py download --model {cfg.get("asr")}',
              file=sys.stderr, flush=True)
        return None
    kwargs = dict(tokens=tokens, encoder=enc, decoder=dec, joiner=joi,
                  num_threads=2, sample_rate=SR, feature_dim=80,
                  enable_endpoint_detection=True)
    if os.path.isfile(bpe):
        kwargs['bpe_vocab'] = bpe
    return sherpa_onnx.OnlineRecognizer.from_transducer(**kwargs)

# ---------------- LRU 翻译缓存 ----------------
class ZhCache:
    def __init__(self, maxsize=512):
        self.d = OrderedDict(); self.max = maxsize
    @staticmethod
    def _norm(t): return ' '.join(t.split()).lower()
    def get(self, text):
        n = self._norm(text)
        if n in self.d:
            self.d.move_to_end(n); return self.d[n]
        pre = n[:24]
        if pre:
            for k in list(self.d.keys()):
                if k.startswith(pre) or pre.startswith(k):
                    self.d.move_to_end(k); return self.d[k]
        return None
    def put(self, text, zh):
        n = self._norm(text)
        self.d[n] = zh; self.d.move_to_end(n)
        while len(self.d) > self.max: self.d.popitem(last=False)

# ---------------- 语言检测: 中文直接显示, 跳过翻译 ----------------
def is_mostly_chinese(text, threshold=0.4):
    """CJK 字符占比 >= 阈值视为中文, 直接显示原文不用翻译。
    日文汉字混排时用假名排除: 含平假名/片假名 → 日文, 不算中文。"""
    if not text: return False
    cjk = sum(1 for ch in text if '\u4e00' <= ch <= '\u9fff' or '\u3400' <= ch <= '\u4dbf')
    kana = sum(1 for ch in text if '\u3040' <= ch <= '\u309f' or '\u30a0' <= ch <= '\u30ff')
    if kana > 0:
        return False  # 有假名 = 日文
    return cjk / max(1, len(text)) >= threshold

# ---------------- 翻译线程 (Hy-MT2, 参考 livecaption) ----------------
_BOILERPLATE_RE = re.compile(
    r'^(?:翻译|译文|以下是翻译|The translation|Translation|Here is the translation|'
    r'Here\'s the translation|结果是|结果)[:：]?\s*', re.I)
_QUOTES = {'“': '”', '"': '"', '「': '」', "'": "'"}

def strip_boilerplate(zh):
    out = zh.strip()
    m = _BOILERPLATE_RE.match(out)
    if not m: return out
    out = out[m.end():].strip()
    c = _QUOTES.get(out[:1])
    if c and len(out) >= 2 and out.endswith(c): out = out[1:-1].strip()
    return out or zh.strip()

TRANSLATE_PROMPT = ("Translate the following text into {lang}. "
                    "Note that you should only output the translated result "
                    "without any additional explanation:\n\n{text}")

class Translator:
    """串行翻译线程: 抢占式 — partial 只留最新一条, final 必译, 保证字幕跟嘴"""
    def __init__(self, emit, lang='Simplified Chinese'):
        self.emit = emit; self.lang = lang
        self.q = []  # (ms, text, is_final)
        self.lock = threading.Lock()
        self.model = self.tokenizer = None
        cfg = load_config()
        cache_size = int(cfg.get('cache_size', 512) or 512)
        self.cache = ZhCache(maxsize=cache_size)
        self.stop = threading.Event()
        self.last_cost_ms = 0.0   # 最近一次翻译耗时(自适应节流用)
        threading.Thread(target=self._run, daemon=True).start()
    def submit(self, ms, text, final=False):
        with self.lock:
            if final:
                # final 必译, 追加队尾
                self.q.append((ms, text, True))
            else:
                # partial 抢占: 丢弃未处理的旧 partial, 只留最新一条
                pending_finals = [x for x in self.q if x[2]]
                self.q = pending_finals + [(ms, text, False)]
    def translate_cost(self):
        """当前翻译线程耗时(毫秒), 供自适应节流"""
        with self.lock:
            return self.last_cost_ms
    def _run(self):
        from mlx_lm import load, generate
        from mlx_lm.sample_utils import make_logits_processors, make_sampler
        from transformers.utils import logging as hf_logging
        hf_logging.set_verbosity_error()
        # 翻译模型优先用本地下载目录 (多语言/按需下载模型), 否则用 HF repo id
        cfg = load_config()
        mt_dir = os.path.join(APP_SUPPORT, 'models', 'mt', cfg.get('mt', 'Hy-MT2-1.8B-8bit'))
        if os.path.isdir(mt_dir) and os.listdir(mt_dir):
            model = mt_dir
        else:
            model = 'mlx-community/Hy-MT2-1.8B-8bit'
        self.model, self.tokenizer = load(model)
        sampler = make_sampler(temp=0.7, top_p=0.6, top_k=20)
        procs = make_logits_processors(repetition_penalty=1.05)
        while not self.stop.is_set():
            item = None
            with self.lock:
                if self.q: item = self.q.pop(0)
            if item is None:
                time.sleep(0.05); continue
            ms, text, is_final = item
            # 仅 final 用缓存(精确+前缀匹配); partial 总是真翻译(保证跟嘴更新)
            if is_final:
                cached = self.cache.get(text)
                if cached is not None:
                    self.emit({'t': 'Z', 'ms': ms, 'text': text, 'zh': cached, 'cached': True, 'lat': 0})
                    continue
            prompt = self.tokenizer.apply_chat_template(
                [{'role': 'user', 'content': TRANSLATE_PROMPT.format(lang=self.lang, text=text)}],
                add_generation_prompt=True)
            t0 = time.time()
            try:
                out = generate(self.model, self.tokenizer, prompt=prompt,
                               max_tokens=128, sampler=sampler, logits_processors=procs)
            except Exception as e:
                print(f'[zhsub] 翻译失败: {e}', file=sys.stderr, flush=True)
                out = ''
            cost_ms = int((time.time() - t0) * 1000)
            with self.lock:
                self.last_cost_ms = cost_ms
            zh = strip_boilerplate(out.strip())
            if zh:
                if is_final:
                    self.cache.put(text, zh)
                self.emit({'t': 'Z', 'ms': ms, 'text': text, 'zh': zh, 'cached': False, 'lat': cost_ms})
            else:
                self.emit({'t': 'Z', 'ms': ms, 'text': text, 'zh': '', 'cached': False, 'lat': cost_ms})

# ---------------- ASR 流式 ----------------
def stream_audio(chunks_iter, emit, lang='Simplified Chinese'):
    rec = make_recognizer()
    tr = Translator(emit, lang=lang)
    if rec is None:
        # 模型未下载: 输出提示事件, 保持进程存活等 floater 引导下载
        cfg = load_config()
        emit({'t': 'Z', 'ms': 0, 'text': '', 'zh': f'⚠ 识别模型未下载: {cfg.get("asr")}',
              'cached': True, 'direct': True, 'notice': True})
        time.sleep(3600)  # 挂起等待, 不退出
        return
    stream = rec.create_stream()
    # 字幕更新间隔: 从配置读 (partial 翻译提交最小间隔, 默认 1200ms)
    try:
        sub_gap = int(load_config().get('sub_gap', 1200) or 1200)
    except Exception:
        sub_gap = 1200
    sub_gap = max(400, min(5000, sub_gap))
    last_partial_ms = -9999
    last_partial = ''
    last_final = ''
    last_translate_ms = -9999
    audio_ms = 0
    for samples in chunks_iter:
        stream.accept_waveform(SR, samples.tolist())
        while rec.is_ready(stream): rec.decode_stream(stream)
        txt = rec.get_result(stream).strip()
        if txt and txt != last_partial and (audio_ms - last_partial_ms) >= PARTIAL_MIN_INTERVAL_S * 1000:
            emit({'t': 'P', 'ms': audio_ms, 'text': txt})
            # 自适应节流: 提交间隔 = sub_gap - 最近翻译耗时(上限), 
            # 翻译慢时自动收紧间隔, 让「间隔+翻译」总节奏稳定不忽快忽慢
            cost = int(tr.translate_cost())
            eff_gap = max(350, sub_gap - cost)
            if (len(txt) >= 4 and not is_mostly_chinese(txt)
                    and (audio_ms - last_translate_ms) >= eff_gap):
                tr.submit(audio_ms, txt, final=False)
                last_translate_ms = audio_ms
            last_partial = txt; last_partial_ms = audio_ms
        if rec.is_endpoint(stream):
            final = rec.get_result(stream).strip()
            if final and final != last_final:
                emit({'t': 'F', 'ms': audio_ms, 'text': final})
                # 只翻译相对上一段的增量尾部(避免整句重复翻译)
                tail = final
                if last_final and final.startswith(last_final):
                    tail = final[len(last_final):].strip()
                if tail and len(tail) >= 4:
                    if is_mostly_chinese(tail):
                        # 识别结果是中文: 直接显示原文, 跳过翻译(零延迟)
                        emit({'t': 'Z', 'ms': audio_ms, 'text': tail, 'zh': tail, 'cached': True, 'direct': True})
                    else:
                        tr.submit(audio_ms, tail, final=True)
                        last_translate_ms = audio_ms
                last_final = final
                # 句末重置流: 英文不累积, 每句独立显示
                rec.reset(stream)
                last_final = ''
                last_partial = ''
                last_partial_ms = -9999
                last_translate_ms = -9999
        audio_ms += 100
    final = rec.get_result(stream).strip()
    if final and final != last_final:
        emit({'t': 'F', 'ms': audio_ms, 'text': final})
        if is_mostly_chinese(final):
            emit({'t': 'Z', 'ms': audio_ms, 'text': final, 'zh': final, 'cached': True, 'direct': True})
        else:
            tr.submit(audio_ms, final, final=True)
    time.sleep(4)  # 等翻译线程排空

def emit(x):
    print(json.dumps(x, ensure_ascii=False), flush=True)

def file_chunks(path):
    import soundfile as sf
    samples, sr = sf.read(path, dtype='float32')
    if sr != SR:
        raise SystemExit(f'需要 {SR}Hz 音频(用 afconvert 转换), 当前 {sr}')
    for i in range(0, len(samples) - CHUNK + 1, CHUNK):
        yield samples[i:i+CHUNK]

def live_chunks(pid):
    import subprocess
    audiotee = os.path.expanduser('~/livecaption/bin/audiotee')
    cmd = [audiotee, '--sample-rate', str(SR)]
    if pid:
        cmd += ['--include-processes', str(pid)]
        print(f'[zhsub] 按进程捕获 pid={pid}', file=sys.stderr, flush=True)
    else:
        print('[zhsub] 捕获全系统音频', file=sys.stderr, flush=True)
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    while True:
        raw = proc.stdout.read(CHUNK * 2)
        if not raw: break
        pcm = np.frombuffer(raw, dtype='<i2').astype(np.float32) / 32768.0
        if len(pcm) < CHUNK:
            pcm = np.pad(pcm, (0, CHUNK - len(pcm)))
        yield pcm

if __name__ == '__main__':
    ap = argparse.ArgumentParser()
    ap.add_argument('--file')
    ap.add_argument('--live', action='store_true')
    ap.add_argument('--pid', type=int)
    ap.add_argument('--lang', default='zh-cn', choices=list(LANGS.keys()))
    a = ap.parse_args()
    lang_name = LANGS.get(a.lang, LANGS['zh-cn'])
    if a.file:
        stream_audio(file_chunks(a.file), emit, lang_name)
    elif a.live and a.pid is not None:
        stream_audio(live_chunks(a.pid), emit, lang_name)
    else:
        ap.print_help()
