import sherpa_onnx, soundfile, time

def test(name, tokens, enc, dec, joiner):
    r = sherpa_onnx.OnlineRecognizer.from_transducer(
        tokens=tokens, encoder=enc, decoder=dec, joiner=joiner,
        num_threads=2, sample_rate=16000, feature_dim=80,
        enable_endpoint_detection=True)
    samples, sr = soundfile.read('/tmp/en_sample_16k.wav', dtype='float32')
    s = r.create_stream()
    t0 = time.time(); first=None; n=0
    CH = 1600
    for i in range(0, len(samples), CH):
        s.accept_waveform(16000, samples[i:i+CH].tolist())
        while r.is_ready(s): r.decode_stream(s)
        txt = r.get_result(s).strip()
        if txt:
            n += 1
            if first is None:
                first = (i/16000, txt)
    print(f'[{name}] 首个部分: 音频@{first[0]:.2f}s → "{first[1][:40]}" | 更新{n}次 | RTF={(time.time()-t0)/(len(samples)/16000):.3f}')
    print(f'          最终: {r.get_result(s)[:70]}')

M1='models/streaming-zipformer-en'
test('20M', f'{M1}/tokens.txt', f'{M1}/encoder-epoch-99-avg-1.onnx', f'{M1}/decoder-epoch-99-avg-1.onnx', f'{M1}/joiner-epoch-99-avg-1.onnx')
M2='models/streaming-zipformer-en-0626'
test('06-26', f'{M2}/tokens.txt', f'{M2}/encoder-epoch-99-avg-1-chunk-16-left-64.onnx', f'{M2}/decoder-epoch-99-avg-1-chunk-16-left-64.onnx', f'{M2}/joiner-epoch-99-avg-1-chunk-16-left-64.onnx')
