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
# 找语音起点(消音)
speech_start = next(i for i, s in enumerate(samples) if abs(s) > 0.01)
speech_start_t = speech_start / 16000
print(f'语音起点: {speech_start_t:.2f}s')

s = r.create_stream()
CH = 1600
t_feed = time.time()
first = None
partial_seen = set()
for i in range(0, len(samples), CH):
    s.accept_waveform(16000, samples[i:i+CH].tolist())
    while r.is_ready(s):
        r.decode_stream(s)
    txt = r.get_result(s).strip()
    if txt and txt not in partial_seen:
        partial_seen.add(txt)
        audio_t = i / 16000
        latency = audio_t - speech_start_t
        if first is None:
            first = (audio_t, txt)
            print(f'[首个部分结果] 音频@{audio_t:.2f}s (语音后{latency:.2f}s): {txt[:50]}')
        else:
            print(f'  [更新] 音频@{audio_t:.2f}s (语音后{latency:.2f}s): {txt[:40]}')
    # 实时节奏: 每100ms音频等100ms墙钟
    dt = (i / 16000) - (time.time() - t_feed)
    if dt > 0: time.sleep(dt)
print(f'最终: {r.get_result(s)}')
