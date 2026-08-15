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

BASE = os.path.expanduser('~/zh-sub-engine')
MDIR = f'{BASE}/models/streaming-zipformer-en-0626'
SR = 16000
CHUNK = SR // 10  # 100ms
PARTIAL_MIN_INTERVAL_S = 0.35

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
    """串行翻译线程: 只在定稿句上调用, 结果经回调发出"""
    def __init__(self, emit, lang='Simplified Chinese'):
        self.emit = emit; self.lang = lang
        self.q = []  # (ms, text)
        self.lock = threading.Lock()
        self.model = self.tokenizer = None
        self.cache = ZhCache()
        self.stop = threading.Event()
        threading.Thread(target=self._run, daemon=True).start()
    def submit(self, ms, text):
        with self.lock: self.q.append((ms, text))
    def _run(self):
        from mlx_lm import load, generate
        from mlx_lm.sample_utils import make_logits_processors, make_sampler
        from transformers.utils import logging as hf_logging
        hf_logging.set_verbosity_error()
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
            ms, text = item
            cached = self.cache.get(text)
            if cached is not None:
                self.emit({'t': 'Z', 'ms': ms, 'text': text, 'zh': cached, 'cached': True})
                continue
            prompt = self.tokenizer.apply_chat_template(
                [{'role': 'user', 'content': TRANSLATE_PROMPT.format(lang=self.lang, text=text)}],
                add_generation_prompt=True)
            try:
                out = generate(self.model, self.tokenizer, prompt=prompt,
                               max_tokens=256, sampler=sampler, logits_processors=procs)
            except Exception as e:
                print(f'[zhsub] 翻译失败: {e}', file=sys.stderr, flush=True)
                out = ''
            zh = strip_boilerplate(out.strip())
            if zh:
                self.cache.put(text, zh)
                self.emit({'t': 'Z', 'ms': ms, 'text': text, 'zh': zh, 'cached': False})
            else:
                self.emit({'t': 'Z', 'ms': ms, 'text': text, 'zh': '', 'cached': False})

# ---------------- ASR 流式 ----------------
def make_recognizer():
    import sherpa_onnx
    return sherpa_onnx.OnlineRecognizer.from_transducer(
        tokens=f'{MDIR}/tokens.txt',
        encoder=f'{MDIR}/encoder-epoch-99-avg-1-chunk-16-left-64.onnx',
        decoder=f'{MDIR}/decoder-epoch-99-avg-1-chunk-16-left-64.onnx',
        joiner=f'{MDIR}/joiner-epoch-99-avg-1-chunk-16-left-64.onnx',
        num_threads=2, sample_rate=SR, feature_dim=80,
        enable_endpoint_detection=True)

def stream_audio(chunks_iter, emit):
    rec = make_recognizer()
    tr = Translator(emit)
    stream = rec.create_stream()
    last_partial_ms = -9999
    last_partial = ''
    last_final = ''
    audio_ms = 0
    for samples in chunks_iter:
        stream.accept_waveform(SR, samples.tolist())
        while rec.is_ready(stream): rec.decode_stream(stream)
        txt = rec.get_result(stream).strip()
        if txt and txt != last_partial and (audio_ms - last_partial_ms) >= PARTIAL_MIN_INTERVAL_S * 1000:
            emit({'t': 'P', 'ms': audio_ms, 'text': txt})
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
                    tr.submit(audio_ms, tail)
                last_final = final
        audio_ms += 100
    final = rec.get_result(stream).strip()
    if final and final != last_final:
        emit({'t': 'F', 'ms': audio_ms, 'text': final})
        tr.submit(audio_ms, final)
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
    a = ap.parse_args()
    if a.file:
        stream_audio(file_chunks(a.file), emit)
    elif a.live and a.pid is not None:
        stream_audio(live_chunks(a.pid), emit)
    else:
        ap.print_help()
