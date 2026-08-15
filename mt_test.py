import sys, time
sys.path.insert(0, '.')
from mlx_lm import load, generate
import mlx_lm.sample_utils as su

t0 = time.time()
model, tokenizer = load('mlx-community/Hy-MT2-1.8B-8bit')
print(f'模型加载 {time.time()-t0:.1f}s')
text = 'The Federal Reserve signaled a possible rate cut in September as inflation continues to cool.'
prompt = tokenizer.apply_chat_template(
    [{'role': 'user', 'content': f'Translate the following text into Simplified Chinese. Note that you should only output the translated result without any additional explanation:\n\n{text}'}],
    add_generation_prompt=True)
sampler = su.make_sampler(temp=0.7, top_p=0.6, top_k=20)
procs = su.make_logits_processors(repetition_penalty=1.05)
t0 = time.time()
out = generate(model, tokenizer, prompt=prompt, max_tokens=256, sampler=sampler, logits_processors=procs)
print(f'翻译 {time.time()-t0:.1f}s → {out!r}')
