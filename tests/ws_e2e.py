import asyncio, sys, time
import numpy as np, sphn, websockets

URL, WAV = sys.argv[1], sys.argv[2]
TAIL = float(sys.argv[3]) if len(sys.argv) > 3 else 14.0


async def main():
    pcm, _ = sphn.read(WAV, sample_rate=24000)
    pcm = np.concatenate([np.zeros(48000, np.float32), pcm[0].astype(np.float32),
                          np.zeros(int(24000 * TAIL), np.float32)])
    enc, dec = sphn.OpusStreamWriter(24000), sphn.OpusStreamReader(24000)
    out = {"samples": 0, "first_audio": None}
    async with websockets.connect(URL, max_size=None) as ws:
        first = await ws.recv()
        print("first msg type", first[0])
        t0 = time.time()

        async def recv():
            try:
                async for m in ws:
                    t = m[0]
                    if t == 1:
                        a = dec.append_bytes(m[1:])
                        if a is not None and len(a):
                            out["samples"] += len(a)
                            out["first_audio"] = out["first_audio"] or time.time() - t0
                    elif t in (2, 7):
                        print(m[1:].decode(errors="replace"), end="", flush=True)
                    else:
                        print(f"\n[type {t}] {m[1:].decode(errors='replace')[:400]}")
            except Exception as e:
                print("\nrecv end:", repr(e)[:200])

        task = asyncio.create_task(recv())
        step = 1920
        try:
            for i in range(0, len(pcm), step):
                b = enc.append_pcm(pcm[i:i + step])
                if b:
                    await ws.send(b"\x01" + b)
                await asyncio.sleep(step / 24000)
        except Exception as e:
            print("\nsend end:", repr(e)[:200])
        task.cancel()
    el = time.time() - t0
    print(f"\n\nwall {el:.1f}s, model audio {out['samples']/24000:.1f}s "
          f"(ratio {out['samples']/24000/el:.2f}), first audio after {out['first_audio']}")


asyncio.run(main())
