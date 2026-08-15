import sherpa_onnx, soundfile, time

M = 'models/streaming-zipformer-en'
r = sherpa_onnx.OnlineRecognizer.from_transducer(
    tokens=f'{M}/tokens.txt',
    encoder=f'{M}/encoder-epoch-99-avg-1.onnx',
    decoder=f'{M}/decoder-epoch-99-avg-1.onnx',
    joiner=f'{M}/joiner-epoch-99-avg-1.onnx',
    num_threads=2, sample_rate=16000, feature_dim=80,
    enable_endpoint_detection=True,
)
samples, sr = soundfile.read('/tmp/en_sample_16k.wav', dtype='float32')
s = r.create_stream()
t0 = time.time(); audio_t = 0.0; first = None; partials = 0
CH = 1600  # 100ms
for i in range(0, len(samples), CH):
    s.accept_waveform(16000, samples[i:i+CH].tolist())
    audio_t = i / 16000
    while r.is_ready(s):
        r.decode_stream(s)
    txt = r.get_result(s).strip()
    if txt and first is None:
        wall = time.time() - t0
        first = (audio_t, wall, txt)
        print(f'[首个部分结果] 音频@{audio_t:.2f}s 墙钟@{wall:.2f}s 延迟={wall-audio_t:.2f}s')
        print(f'  文本: {txt}')
    if txt:
        partials += 1
print(f'部分结果更新次数: {partials}')
print(f'最终识别: {r.get_result(s)}')
print(f'总处理耗时: {time.time()-t0:.2f}s (音频 {len(samples)/16000:.1f}s) RTF={ (time.time()-t0)/(len(samples)/16000):.2f}')
