#!/usr/bin/env python3
"""zhsub-mt — 独立翻译助手(被 zhsub-app 调用)
从 stdin 读英文行 → Hy-MT2 翻译 → stdout 输出 {"zh": "..."}
"""
import json, os, sys, threading
sys.path.insert(0, os.path.expanduser('~/zh-sub-engine'))

from collections import OrderedDict

class Cache:
    def __init__(self, maxsize=512):
        self.d = OrderedDict(); self.max = maxsize
    def get(self, t):
        n = ' '.join(t.split()).lower()
        if n in self.d:
            self.d.move_to_end(n); return self.d[n]
        return None
    def put(self, t, zh):
        n = ' '.join(t.split()).lower()
        self.d[n] = zh; self.d.move_to_end(n)
        while len(self.d) > self.max: self.d.popitem(last=False)

_cache = Cache()
_model = None
_tokenizer = None
_sampler = None
_procs = None
_prompt = ("Translate the following text into {lang}. "
           "Note that you should only output the translated result "
           "without any additional explanation:\n\n{text}")

def load():
    global _model, _tokenizer, _sampler, _procs
    if _model is not None:
        return _sampler, _procs
    from mlx_lm import load
    from mlx_lm.sample_utils import make_logits_processors, make_sampler
    from transformers.utils import logging as hf_logging
    hf_logging.set_verbosity_error()
    _model, _tokenizer = load('mlx-community/Hy-MT2-1.8B-8bit')
    _sampler = make_sampler(temp=0.7, top_p=0.6, top_k=20)
    _procs = make_logits_processors(repetition_penalty=1.05)
    return _sampler, _procs

def translate(text, lang):
    global _model, _tokenizer
    hit = _cache.get(text)
    if hit is not None: return hit
    sampler, procs = load()
    from mlx_lm import generate
    prompt = _tokenizer.apply_chat_template(
        [{'role': 'user', 'content': _prompt.format(lang=lang, text=text)}],
        add_generation_prompt=True)
    try:
        out = generate(_model, _tokenizer, prompt=prompt, max_tokens=256,
                       sampler=sampler, logits_processors=procs)
    except Exception as e:
        print(f'[zhsub-mt] 翻译失败: {e}', file=sys.stderr, flush=True)
        return ''
    zh = out.strip()
    if zh:
        _cache.put(text, zh)
    return zh

if __name__ == '__main__':
    lang = sys.argv[1] if len(sys.argv) > 1 else 'Simplified Chinese'
    # 预加载模型
    try:
        load()
    except Exception as e:
        print(json.dumps({'error': str(e)}), flush=True)
    for line in sys.stdin:
        line = line.rstrip('\n')
        if not line.strip():
            continue
        zh = translate(line, lang)
        print(json.dumps({'zh': zh}, ensure_ascii=False), flush=True)
